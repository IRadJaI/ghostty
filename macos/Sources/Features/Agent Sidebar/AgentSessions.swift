import AppKit
import UserNotifications

// Fork addition (agent-sidebar): notifications, restoring the previous session, hook script upkeep.

// MARK: - Environment

enum AgentEnvironment {
    /// Markers of a Claude Code session; inherited, they make Claude Code in the tabs run as its child.
    private static let sessionMarkers = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SESSION_ID",
    ]

    static func scrubSessionMarkers() {
        for name in sessionMarkers {
            unsetenv(name)
        }
    }
}

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
        // The app's own badge already counts tabs whose bell rang.
        let bellCounts = (NSApp.delegate as? AppDelegate)?.ghostty.config.bellFeatures.contains(.attention) ?? false

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
            if state == .waiting, !(bellCounts && tab.hasBell) {
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

        let unseen = tabs.filter { unread.contains($0.stableID) && !(bellCounts && $0.hasBell) }.count
        let count = defaults.bool(forKey: AgentSidebarDefaults.dockBadge) ? waiting + unseen : 0
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

    // MARK: Permission

    /// What macOS allows this app to show, in words, and whether it is enough.
    nonisolated static func permission(
        _ completion: @escaping (_ text: String, _ allowed: Bool, _ asked: Bool) -> Void
    ) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            var allowed = false
            switch settings.authorizationStatus {
            case .notDetermined: text = "Not asked yet"
            case .denied: text = "Turned off in System Settings"
            default:
                allowed = settings.alertSetting == .enabled
                text = allowed ? "Allowed" : "Allowed, but banners are off in System Settings"
            }
            let asked = settings.authorizationStatus != .notDetermined
            DispatchQueue.main.async { completion(text, allowed, asked) }
        }
    }

    /// Asks for permission if needed and posts a sample notification.
    nonisolated static func sendTest(_ completion: @escaping (_ failure: String?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else {
                let reason = error?.localizedDescription ?? "macOS did not allow notifications for this app."
                DispatchQueue.main.async { completion(reason) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Claude Code needs you"
            content.subtitle = "Test notification"
            content.body = "This is how an agent asks for your attention."
            content.sound = .default
            content.userInfo = [testKey: true]
            center.add(UNNotificationRequest(identifier: "agent-sidebar-test", content: content, trigger: nil)) { error in
                DispatchQueue.main.async { completion(error?.localizedDescription) }
            }
        }
    }

    private static let testKey = "agentSidebarTest"
    nonisolated(unsafe) static var lastTestResult = "not run"
    nonisolated(unsafe) static var lastSettings = "unknown"

    private static func identifier(_ tabID: String) -> String {
        "agent-sidebar-\(tabID)"
    }

    /// True for the notifications posted here.
    nonisolated static func isOwn(_ notification: UNNotification) -> Bool {
        let info = notification.request.content.userInfo
        return info[tabKey] != nil || info[testKey] != nil || info[AgentUpstreamCheck.notificationKey] != nil
    }

    /// Switches to the tab of a clicked notification.
    nonisolated static func handle(_ response: UNNotificationResponse) -> Bool {
        let info = response.notification.request.content.userInfo
        if info[AgentUpstreamCheck.notificationKey] != nil {
            Task { @MainActor in
                AgentSettingsWindowController.shared.show(pane: "Advanced")
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
        /// Where that session was working; the shell may be elsewhere.
        var sessionCwd: String?
    }

    private struct Snapshot: Codable {
        var saved: Date
        var tabs: [SavedTab]
    }

    // A debug build must not offer or overwrite the release build's tabs.
    #if DEBUG
    private static let fileName = "last-session.debug.json"
    #else
    private static let fileName = "last-session.json"
    #endif

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostty-agents/\(fileName)")
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
                session: tab.agent == .claude ? tab.sessionID : nil,
                sessionCwd: tab.agent == .claude ? tab.sessionCwd : nil)
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
        var resume: [(tab: AgentSidebarModel.Tab, saved: SavedTab)] = []
        /// Empty shells from the launch that no saved tab matched.
        var spare: [AgentSidebarModel.Tab] = []

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
                if tab.session != nil {
                    plan.resume.append((live, tab))
                }
            } else {
                plan.open.append(tab)
            }
        }
        plan.spare = free
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
            let place = (Self.sessionDirectory(tab) ?? tab.cwd)
                .map { AgentSidebarFormat.abbreviate(path: $0) } ?? tab.title
            return place + (tab.session != nil ? "  —  Claude Code" : "")
        }
        entries += plan.resume.map { entry in
            let place = (Self.sessionDirectory(entry.saved) ?? entry.tab.pwd)
                .map { AgentSidebarFormat.abbreviate(path: $0) } ?? entry.tab.title
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

        var open = plan.open
        for (tab, saved) in plan.resume {
            guard let resume = Self.resumeCommand(saved) else { continue }
            var command = resume
            if let cwd = Self.sessionDirectory(saved), cwd != tab.pwd {
                // Typed only where it is safe and the shell takes this syntax.
                guard Self.posixShells.contains(model.frontProcessName(tab) ?? ""),
                      let quoted = Self.shellQuoted(cwd)
                else {
                    open.append(saved)
                    continue
                }
                command = "cd -- \(quoted) && " + command
            }
            guard model.hasShellInFront(tab),
                  let controller = model.window(for: tab)?.windowController as? TerminalController,
                  let surface = controller.focusedSurface?.surfaceModel
            else { continue }
            // Pasted text waits at the prompt; return is sent as a key.
            surface.sendText(command)
            _ = surface.perform(action: "text:\\r")
        }

        var after = window
        var opened = false
        for tab in open {
            var config = Ghostty.SurfaceConfiguration()
            if let cwd = Self.sessionDirectory(tab) ?? tab.cwd, FileManager.default.fileExists(atPath: cwd) {
                config.workingDirectory = cwd
            }
            if let command = Self.resumeCommand(tab) {
                config.initialInput = command + "\n"
            }
            // Each tab goes after the previous one to keep the saved order.
            let created = TerminalController.newTab(appDelegate.ghostty, from: after, withBaseConfig: config)
            after = created?.window ?? after
            opened = opened || created != nil
        }

        guard opened else { return }
        let spare = plan.spare.map(\.id)
        // After the sheet is gone and the new tabs are in place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in
                for tab in model.tabs where spare.contains(tab.id) {
                    guard model.hasShellInFront(tab),
                          let controller = model.window(for: tab)?.windowController as? TerminalController,
                          !controller.surfaceTree.contains(where: { $0.needsConfirmQuit }),
                          (controller.window?.tabGroup?.windows.count ?? 0) > 1
                    else { continue }
                    controller.closeTabImmediately()
                }
            }
        }
    }

    /// Nil without a valid id: it comes from a file, so only what an id contains is allowed.
    private static func resumeCommand(_ tab: SavedTab) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard let session = tab.session, !session.isEmpty,
              session.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return "claude --resume \(session)"
    }

    private static let posixShells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]

    /// Where to resume the session: its project as Claude Code files it, else where it last worked.
    private static func sessionDirectory(_ tab: SavedTab) -> String? {
        guard let session = tab.session else { return nil }
        if let project = projectDirectory(session: session) {
            return project
        }
        guard let cwd = tab.sessionCwd, cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) else {
            return nil
        }
        return cwd
    }

    /// The directory whose name Claude Code used for the folder that holds the session's transcript.
    static func projectDirectory(session: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !session.isEmpty, session.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        let manager = FileManager.default
        let projects = manager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var newest: (url: URL, modified: Date)?
        for folder in (try? manager.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let url = projects.appendingPathComponent(folder).appendingPathComponent("\(session).jsonl")
            guard let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                continue
            }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        guard let transcript = newest?.url, let handle = try? FileHandle(forReadingFrom: transcript) else {
            return nil
        }
        defer { try? handle.close() }

        // The session may have moved between directories; its start and its end name them.
        let chunk = 256 * 1024
        var data = (try? handle.read(upToCount: chunk)) ?? Data()
        if let size = try? handle.seekToEnd(), size > UInt64(chunk),
           (try? handle.seek(toOffset: size - UInt64(chunk))) != nil {
            data.append(UInt8(ascii: "\n"))
            data.append((try? handle.read(upToCount: chunk)) ?? Data())
        }

        let folder = transcript.deletingLastPathComponent().lastPathComponent
        var seen = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: Data("\"cwd\"".utf8)) != nil {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let cwd = entry["cwd"] as? String, seen.insert(cwd).inserted
            else { continue }
            // Claude Code names the folder after the path with every other character as a dash.
            let encoded = String(cwd.unicodeScalars.map { scalar -> Character in
                scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
            })
            var isDirectory: ObjCBool = false
            if encoded == folder, manager.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue {
                return cwd
            }
        }
        return nil
    }

    /// Single-quoted, or nil when the path has a quote, a backslash or a control character.
    private static func shellQuoted(_ path: String) -> String? {
        let unsafe = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "'\\"))
        guard path.unicodeScalars.allSatisfy({ !unsafe.contains($0) }) else { return nil }
        return "'\(path)'"
    }

    private func finish() {
        previous = nil
        recording = true
    }
}
