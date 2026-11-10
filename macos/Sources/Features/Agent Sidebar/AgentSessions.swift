import AppKit
import UserNotifications

// Fork addition (agent-sidebar): notifications, restoring the previous session, hook script upkeep.

// MARK: - Hook script

enum AgentHookInstaller {
    /// Replaces the installed hook script when the app carries a newer one.
    static func refreshInstalledScript() {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostty-agents/bin/ghostty-agent-hook")
        guard let bundled = Bundle.main.url(forResource: "ghostty-agent-hook", withExtension: nil),
              let new = try? Data(contentsOf: bundled),
              let old = try? Data(contentsOf: installed),
              new != old
        else { return }
        let staged = installed.appendingPathExtension("new")
        guard (try? new.write(to: staged)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)) != nil
        else { return }
        _ = try? FileManager.default.replaceItemAt(installed, withItemAt: staged)
    }
}

// MARK: - Notifications

/// Tabs that wait for the user or finished unseen, for the Dock icon.
enum AgentBadge {
    static var count = 0
}

/// Posts a system notification when an agent starts waiting for the user or finishes while the user is looking elsewhere.
@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()

    private static let tabKey = "agentSidebarTab"

    private var lastStates: [String: AgentState] = [:]
    private var primed = false
    private var askedPermission = false
    private var notified = Set<String>()

    /// `isFront` tells whether the user is looking at a tab right now.
    func update(_ tabs: [AgentSidebarModel.Tab], isFront: (AgentSidebarModel.Tab) -> Bool) {
        let defaults = UserDefaults.standard
        var states: [String: AgentState] = [:]
        var waiting = 0

        for tab in tabs {
            guard !tab.stableID.isEmpty, let state = tab.state else { continue }
            let id = tab.stableID
            states[id] = state
            let changed = primed && lastStates[id] != state

            let front = isFront(tab)
            if front {
                unread.remove(id)
                if notified.remove(id) != nil {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: [Self.identifier(id)])
                }
            } else if changed, state == .done {
                unread.insert(id)
            }
            if state != .done {
                unread.remove(id)
            }
            if state == .waiting {
                waiting += 1
            }
            guard changed, !front else { continue }

            switch state {
            case .waiting where defaults.bool(forKey: AgentSidebarDefaults.notifyWaiting):
                post(tab, title: "\(tab.agent?.displayName ?? "Agent") needs you",
                     sound: defaults.string(forKey: AgentSidebarDefaults.soundWaiting))
            case .done where defaults.bool(forKey: AgentSidebarDefaults.notifyDone):
                post(tab, title: "\(tab.agent?.displayName ?? "Agent") finished",
                     sound: defaults.string(forKey: AgentSidebarDefaults.soundDone))
            default:
                break
            }
        }

        unread.formIntersection(states.keys)
        lastStates = states
        primed = true

        let count = defaults.bool(forKey: AgentSidebarDefaults.dockBadge) ? waiting + unread.count : 0
        if count != AgentBadge.count {
            AgentBadge.count = count
            (NSApp.delegate as? AppDelegate)?.setDockBadge()
        }
    }

    /// Tabs whose agent finished while the user was looking elsewhere.
    private(set) var unread = Set<String>()
    private func post(_ tab: AgentSidebarModel.Tab, title: String, sound: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = tab.title
        if tab.state == .waiting, let message = tab.message, !message.isEmpty {
            content.body = message
        } else if let pwd = tab.pwd, !pwd.isEmpty {
            content.body = AgentSidebarFormat.abbreviate(path: pwd)
        }
        if let sound, !sound.isEmpty {
            // Found in /System/Library/Sounds.
            content.sound = UNNotificationSound(named: UNNotificationSoundName("\(sound).aiff"))
        }
        content.userInfo = [Self.tabKey: tab.stableID]
        notified.insert(tab.stableID)

        let request = UNNotificationRequest(
            identifier: Self.identifier(tab.stableID), content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        if askedPermission {
            center.add(request)
        } else {
            askedPermission = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                center.add(request)
            }
        }
    }

    private static func identifier(_ tabID: String) -> String {
        "agent-sidebar-\(tabID)"
    }

    /// True for the notifications posted here.
    nonisolated static func isOwn(_ notification: UNNotification) -> Bool {
        let info = notification.request.content.userInfo
        return info[tabKey] != nil || info[AgentUpstreamCheck.notificationKey] != nil
    }

    /// Switches to the tab of a clicked notification.
    nonisolated static func handle(_ response: UNNotificationResponse) -> Bool {
        let info = response.notification.request.content.userInfo
        if info[AgentUpstreamCheck.notificationKey] != nil {
            Task { @MainActor in
                UserDefaults.standard.set("Advanced", forKey: "AgentSettingsPane")
                AgentSettingsWindowController.shared.show()
            }
            return true
        }
        guard let tabID = info[tabKey] as? String else {
            return false
        }
        Task { @MainActor in
            let model = AgentSidebarModel.shared
            model.refresh()
            if let tab = model.tabs.first(where: { $0.stableID == tabID }) {
                NSApp.activate(ignoringOtherApps: true)
                model.select(tab)
            }
        }
        return true
    }
}

// MARK: - Previous session

/// Remembers the open tabs and offers to bring them back on the next launch, resuming the Claude Code sessions that were running in them.
@MainActor
final class AgentSessionRestore {
    static let shared = AgentSessionRestore()

    struct SavedTab: Codable, Equatable {
        var title: String
        var cwd: String?
        /// Claude Code session that was running in the tab.
        var session: String?
    }

    private struct Snapshot: Codable {
        var saved: Date
        var tabs: [SavedTab]
    }

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostty-agents/last-session.json")
    }

    /// What the previous launch left behind; nil once handled.
    private var previous: [SavedTab]?
    private var promptScheduled = false
    private var restoreAttempts = 0
    private var recording = false
    private var lastWritten: [SavedTab] = []

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            previous = snapshot.tabs
        } else {
            recording = true
        }
    }

    /// Called on every refresh of the sidebar model.
    func update(_ tabs: [AgentSidebarModel.Tab]) {
        guard !tabs.isEmpty else { return }

        if previous != nil {
            if !promptScheduled {
                promptScheduled = true
                // Give the shells time to start and report their directories.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Task { @MainActor in self.offerRestore() }
                }
            }
            return
        }

        guard recording else { return }
        let saved = tabs.map { tab in
            SavedTab(
                title: tab.title,
                cwd: tab.pwd,
                session: tab.agent == .claude ? tab.sessionID : nil)
        }
        guard saved != lastWritten else { return }
        lastWritten = saved
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Snapshot(saved: Date(), tabs: saved)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Restoring

    private struct Plan {
        /// Tabs to open (the session, if any, is resumed in the new tab).
        var open: [SavedTab] = []
        /// Sessions to resume in tabs that are already there.
        var resume: [(tab: AgentSidebarModel.Tab, session: String)] = []

        var isEmpty: Bool { open.isEmpty && resume.isEmpty }
        var sessionCount: Int { resume.count + open.filter { $0.session != nil }.count }
    }

    /// Matches the saved tabs against the tabs that exist now.
    private func plan(for saved: [SavedTab]) -> Plan {
        var plan = Plan()
        let model = AgentSidebarModel.shared
        var free = model.tabs.filter { $0.agent == nil && model.hasShellInFront($0) }
        for tab in saved {
            if let index = free.firstIndex(where: { $0.pwd == tab.cwd }) {
                let live = free.remove(at: index)
                if let session = tab.session {
                    plan.resume.append((live, session))
                }
            } else {
                plan.open.append(tab)
            }
        }
        return plan
    }

    private func offerRestore() {
        guard let saved = previous else { return }
        let mode = UserDefaults.standard.string(forKey: AgentSidebarDefaults.restoreMode) ?? "ask"
        let model = AgentSidebarModel.shared
        model.refresh()
        // A shell that has not reported its directory yet cannot be matched.
        if model.tabs.contains(where: { $0.pwd == nil }), restoreAttempts < 5 {
            restoreAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Task { @MainActor in self.offerRestore() }
            }
            return
        }
        let plan = plan(for: saved)

        guard mode != "never", !plan.isEmpty,
              let window = NSApp.keyWindow ?? model.tabs.first.flatMap({ model.window(for: $0) })
        else {
            finish()
            return
        }
        if mode == "always" {
            apply(plan, in: window)
            finish()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore the previous session?"
        var parts: [String] = []
        if !plan.open.isEmpty {
            parts.append(plan.open.count == 1 ? "1 tab" : "\(plan.open.count) tabs")
        }
        if plan.sessionCount > 0 {
            parts.append(plan.sessionCount == 1
                ? "1 Claude Code session" : "\(plan.sessionCount) Claude Code sessions")
        }
        // List exactly what "Restore" is going to do.
        var entries = plan.open.map { tab -> String in
            let place = tab.cwd.map { AgentSidebarFormat.abbreviate(path: $0) } ?? tab.title
            return place + (tab.session != nil ? "  —  Claude Code" : "")
        }
        entries += plan.resume.map { entry in
            let place = entry.tab.pwd.map { AgentSidebarFormat.abbreviate(path: $0) } ?? entry.tab.title
            return place + "  —  Claude Code"
        }
        var lines = entries.prefix(8).map { "•  " + $0 }
        if entries.count > 8 {
            lines.append("•  and \(entries.count - 8) more")
        }
        alert.informativeText = "Ghostty can bring back " + parts.joined(separator: " and ")
            + " from the last time it was open.\n\n" + lines.joined(separator: "\n")
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                if alert.suppressionButton?.state == .on {
                    UserDefaults.standard.set(
                        response == .alertFirstButtonReturn ? "always" : "never",
                        forKey: AgentSidebarDefaults.restoreMode)
                }
                if response == .alertFirstButtonReturn {
                    // Plan again: the tabs may have changed while the sheet was up.
                    self.apply(self.plan(for: saved), in: window)
                }
                self.finish()
            }
        }
    }

    private func apply(_ plan: Plan, in window: NSWindow) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let model = AgentSidebarModel.shared

        for (tab, session) in plan.resume {
            // Typed as keys: pasted text would wait for return at the prompt.
            guard Self.resumeCommand(session) != nil, model.hasShellInFront(tab),
                  let controller = model.window(for: tab)?.windowController as? TerminalController,
                  let surface = controller.focusedSurface
            else { continue }
            _ = surface.surfaceModel?.perform(action: "text:claude --resume \(session)\\r")
        }

        var after = window
        for tab in plan.open {
            var config = Ghostty.SurfaceConfiguration()
            if let cwd = tab.cwd, FileManager.default.fileExists(atPath: cwd) {
                config.workingDirectory = cwd
            }
            if let session = tab.session, let command = Self.resumeCommand(session) {
                config.initialInput = command
            }
            // Each tab goes after the previous one to keep the saved order.
            let created = TerminalController.newTab(appDelegate.ghostty, from: after, withBaseConfig: config)
            after = created?.window ?? after
        }
    }

    /// The id comes from a file; allow only what a session id contains.
    private static func resumeCommand(_ session: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !session.isEmpty, session.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "claude --resume \(session)\n"
    }

    private func finish() {
        previous = nil
        recording = true
    }
}
