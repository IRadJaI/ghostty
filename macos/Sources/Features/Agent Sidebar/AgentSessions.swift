import AppKit
import UserNotifications

// Fork addition (agent-sidebar): things that follow the agents across tabs
// and launches: system notifications, restoring the previous session, and
// keeping the installed hook script current.

// MARK: - Hook script

enum AgentHookInstaller {
    /// Replaces the installed hook script when the app carries a newer one.
    /// Does nothing unless the hooks were installed before.
    static func refreshInstalledScript() {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostty-agents/bin/ghostty-agent-hook")
        guard let bundled = Bundle.main.url(forResource: "ghostty-agent-hook", withExtension: nil),
              let new = try? Data(contentsOf: bundled),
              let old = try? Data(contentsOf: installed),
              new != old
        else { return }
        try? new.write(to: installed, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
    }
}

// MARK: - Notifications

/// Posts a system notification when an agent starts waiting for the user or
/// finishes while the user is looking elsewhere.
@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()

    private static let tabKey = "agentSidebarTab"

    private var lastStates: [String: AgentState] = [:]
    private var primed = false
    private var askedPermission = false

    /// `isFront` tells whether the user is looking at a tab right now.
    func update(_ tabs: [AgentSidebarModel.Tab], isFront: (AgentSidebarModel.Tab) -> Bool) {
        let defaults = UserDefaults.standard
        var states: [String: AgentState] = [:]

        for tab in tabs {
            guard !tab.stableID.isEmpty, let state = tab.state else { continue }
            states[tab.stableID] = state

            let front = isFront(tab)
            if front {
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: [Self.identifier(tab.stableID)])
            }
            guard primed, !front, lastStates[tab.stableID] != state else { continue }

            switch state {
            case .waiting where defaults.bool(forKey: AgentSidebarDefaults.notifyWaiting):
                post(tab, title: "\(tab.agent?.displayName ?? "Agent") needs you")
            case .done where defaults.bool(forKey: AgentSidebarDefaults.notifyDone):
                post(tab, title: "\(tab.agent?.displayName ?? "Agent") finished")
            default:
                break
            }
        }

        lastStates = states
        primed = true
    }

    private func post(_ tab: AgentSidebarModel.Tab, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = tab.title
        if tab.state == .waiting, let message = tab.message, !message.isEmpty {
            content.body = message
        } else if let pwd = tab.pwd, !pwd.isEmpty {
            content.body = AgentSidebarFormat.abbreviate(path: pwd)
        }
        if UserDefaults.standard.bool(forKey: AgentSidebarDefaults.notifySound) {
            content.sound = .default
        }
        content.userInfo = [Self.tabKey: tab.stableID]

        let request = UNNotificationRequest(
            identifier: Self.identifier(tab.stableID), content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        if askedPermission {
            center.add(request)
        } else {
            askedPermission = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                center.add(request)
            }
        }
    }

    private static func identifier(_ tabID: String) -> String {
        "agent-sidebar-\(tabID)"
    }

    /// True for the notifications posted here.
    nonisolated static func isOwn(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo[tabKey] != nil
    }

    /// Switches to the tab of a clicked notification. Returns false when the
    /// notification belongs to someone else.
    nonisolated static func handle(_ response: UNNotificationResponse) -> Bool {
        guard let tabID = response.notification.request.content.userInfo[tabKey] as? String else {
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

/// Remembers the open tabs and offers to bring them back on the next launch,
/// resuming the Claude Code sessions that were running in them.
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

    /// Matches the saved tabs against the tabs that exist now: Ghostty may
    /// have restored the windows itself, and a fresh launch has one tab.
    private func plan(for saved: [SavedTab]) -> Plan {
        var plan = Plan()
        var free = AgentSidebarModel.shared.tabs.filter { $0.agent == nil }
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
            guard let command = Self.resumeCommand(session),
                  let controller = model.window(for: tab)?.windowController as? TerminalController,
                  let surface = controller.focusedSurface
            else { continue }
            surface.surfaceModel?.sendText(command)
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
