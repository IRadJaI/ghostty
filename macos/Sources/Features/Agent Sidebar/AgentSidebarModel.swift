import AppKit
import Combine
import Darwin

// Fork addition (agent-sidebar): the bridge between Ghostty's terminal
// windows and the sidebar UI.
//
// Ghostty uses native macOS tabs: every tab is its own NSWindow and AppKit
// groups them in an NSWindowTabGroup. Each of those windows hosts its own
// copy of the sidebar view, so the state lives in this one shared model and
// every copy renders the tabs of its own tab group.

/// Shared state for every sidebar in the app.
@MainActor
final class AgentSidebarModel: ObservableObject {
    static let shared = AgentSidebarModel()

    /// One native tab (one terminal window in a tab group).
    struct Tab: Identifiable, Equatable {
        /// Identity of the tab's NSWindow.
        let id: ObjectIdentifier
        /// Identity of the tab group (or of the window when it has no group).
        let groupID: ObjectIdentifier
        /// The tab id agent tooling uses (see `AgentControlOperations`).
        var stableID: String = ""
        var title: String
        var pwd: String?
        var isSelected: Bool
        var hasBell: Bool
        var agent: AgentKind?
        var state: AgentState?
        var message: String?
        /// The agent's own session id, when its hooks report one.
        var sessionID: String?
        /// The directory the agent's session works in; not always the shell's.
        var sessionCwd: String?
        /// Token usage of the agent's session, when its transcript is found.
        var usage: AgentUsage?
        /// The agent finished while the user was looking elsewhere.
        var unread = false
        /// The user's own letters for the collapsed sidebar.
        var shortLabel: String?
        /// The panes of a split tab, for restoring it.
        var layout: AgentSessionRestore.SavedPane?
        var git: AgentGitInfo?

        /// The state in words; the agent's own message where it says more.
        var statusText: String? {
            guard let state else { return nil }
            // "Done" carries a note only when the hook parser wrote one.
            if state != .working, state != .idle, let message, !message.isEmpty {
                return message
            }
            return state.label
        }

        /// The agent is blocked on the user, or the terminal rang its bell.
        var needsAttention: Bool {
            state == .waiting || hasBell
        }
    }

    /// Sent by hand before every change below.
    let objectWillChange = ObservableObjectPublisher()

    private(set) var tabs: [Tab] = [] {
        willSet { objectWillChange.send() }
    }

    private(set) var recentSessions: [AgentRecentSession] = [] {
        willSet { objectWillChange.send() }
    }

    /// Progress of the agent's fix for a failed command, as reported by the
    /// agent pane (`autofix_state` events, the same ones Windows Terminal's
    /// bottom bar listens to).
    struct Autofix: Equatable {
        /// `detected`, `pending`, `review` or `cleared`.
        var state: String
        var paneID: String
        var summary: String
    }

    /// Error-fix state per stable tab id.
    private(set) var autofix: [String: Autofix] = [:] {
        willSet { objectWillChange.send() }
    }

    func applyAutofix(_ state: Autofix, tabID: String?) {
        // Without a tab id the event is about the tab the user is in.
        let key = tabID ?? tabs.first { windows[$0.id]?.window === NSApp.keyWindow }?.stableID ?? ""
        guard !key.isEmpty else { return }
        if state.state == "cleared" {
            if autofix[key] != nil {
                autofix[key] = nil
            }
        } else if autofix[key] != state {
            autofix[key] = state
        }
    }

    /// Handles a button of the error-fix bar: `autofix_execute_from_detected`,
    /// `autofix_execute` or `autofix_dismiss_suggestion`.
    ///
    /// With the WTA agent pane the action goes to it as an event. Otherwise
    /// "Fix" opens Claude Code next to the failed command and hands it the
    /// terminal output.
    func sendAutofixAction(_ method: String, tabID: String) {
        guard let state = autofix[tabID] else { return }
        let command = UserDefaults.standard.string(forKey: AgentSidebarDefaults.agentPaneCommand)
            ?? AgentSidebarDefaults.defaultAgentPaneCommand
        if command == AgentSidebarDefaults.wtaAgentPaneCommand {
            AgentControlServer.shared.broadcast([
                "type": "event",
                "method": method,
                "params": ["pane_id": state.paneID, "tab_id": tabID],
            ])
            if method == "autofix_dismiss_suggestion" {
                autofix[tabID] = nil
            }
            return
        }

        if method != "autofix_dismiss_suggestion" {
            fixWithClaude(state)
        }
        autofix[tabID] = nil
    }

    private func fixWithClaude(_ state: Autofix) {
        let context = try? AgentControlOperations.perform(
            "pane_context", ["target": state.paneID, "max_lines": 60, "max_chars": 6000]) as? [String: Any]
        let output = context?["content"] as? String ?? ""
        let prompt = """
            A command just failed in my terminal (\(state.summary)).
            Here is the end of the terminal output:

            \(output)

            Explain briefly what went wrong and fix it. Ask before doing anything destructive.
            """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-agent-fix-\(UUID().uuidString).txt")
        guard (try? prompt.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        _ = try? AgentControlOperations.perform("split_pane", [
            "target": state.paneID,
            "direction": "right",
            "command": "/bin/zsh -lic 'p=$(cat \"$1\"); rm -f \"$1\"; exec claude \"$p\"' fix '\(file.path)'",
            "agent_pane": true,
            "focus": true,
            "wait": true,
        ])
    }

    /// Called when a command finishes in a shell pane.
    func commandFinished(paneID: String, tabID: String, exitCode: Int, isAgentPane: Bool) {
        // WTA detects failures itself and reports them as autofix events.
        let command = UserDefaults.standard.string(forKey: AgentSidebarDefaults.agentPaneCommand)
        guard !isAgentPane, !tabID.isEmpty, command != AgentSidebarDefaults.wtaAgentPaneCommand else { return }
        // 130 is ctrl+c: the user stopped the command on purpose.
        if exitCode == 0 || exitCode == 130 {
            if autofix[tabID]?.paneID == paneID {
                autofix[tabID] = nil
            }
        } else {
            let state = Autofix(state: "detected", paneID: paneID, summary: "Command failed (exit \(exitCode))")
            if autofix[tabID] != state {
                autofix[tabID] = state
            }
        }
    }

    /// Asks the agent to fix the last failed command of the key window's tab.
    func fixLastError() {
        guard let tab = tabs.first(where: { windows[$0.id]?.window === NSApp.keyWindow }),
              let state = autofix[tab.stableID]
        else { return }
        sendAutofixAction(state.state == "review" ? "autofix_execute" : "autofix_execute_from_detected", tabID: tab.stableID)
    }

    /// How the sidebar, the status bar and the titlebar strip are painted,
    /// following the terminal's `background-blur` and `background-opacity`.
    enum Chrome: Equatable {
        /// The system sidebar material (blurred).
        case material
        /// Nothing: the window is already glass.
        case glass
        /// The terminal's background color: translucent without blur.
        case flat(NSColor)
    }

    private(set) var chrome: Chrome = .material {
        willSet { objectWillChange.send() }
    }

    private func currentChrome() -> Chrome {
        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config else { return .material }
        switch config.backgroundBlur {
        case .macosGlassRegular, .macosGlassClear:
            return .glass
        case .disabled where config.backgroundOpacity < 1:
            return .flat(NSColor(config.backgroundColor).withAlphaComponent(config.backgroundOpacity))
        default:
            return .material
        }
    }

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    private struct GitCacheEntry {
        var info: AgentGitInfo?
        var updated: Date
        var loading: Bool
    }

    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var gitCache: [String: GitCacheEntry] = [:]
    private var recentUpdated: Date = .distantPast
    private var recentLoading = false
    private var usageScanned: Date = .distantPast
    private let workQueue = DispatchQueue(label: "com.mitchellh.ghostty.agent-sidebar", qos: .utility)

    private static let refreshInterval: TimeInterval = 1.0
    private static let gitRefreshInterval: TimeInterval = 5.0
    private static let recentRefreshInterval: TimeInterval = 30.0

    private init() {
        UserDefaults.standard.register(defaults: AgentSidebarDefaults.registration)
    }

    // MARK: Lifecycle

    /// Starts periodic refreshes. Safe to call repeatedly; every sidebar view
    /// calls this when it appears.
    func start() {
        guard timer == nil else {
            refresh()
            return
        }

        AgentSidebarMenu.shared.install()
        AgentHookInstaller.refreshInstalledScript()
        AgentUpstreamCheck.shared.start()

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                AgentSidebarModel.shared.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .ghosttyConfigDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Wait a tick so AppKit finishes updating the tab group.
                DispatchQueue.main.async {
                    Task { @MainActor in
                        AgentSidebarModel.shared.refresh()
                    }
                }
            }
            observers.append(observer)
        }

        refresh()
    }

    // MARK: Snapshot

    /// The tab-group identity the sidebar uses to pick "its" tabs.
    static func groupID(for window: NSWindow) -> ObjectIdentifier {
        if let group = window.tabGroup {
            return ObjectIdentifier(group)
        }
        return ObjectIdentifier(window)
    }

    /// Rebuilds the list of tabs from the live AppKit windows.
    func refresh() {
        let defaults = UserDefaults.standard
        let wantGit = defaults.bool(forKey: AgentSidebarDefaults.showGitRepo)
            || defaults.bool(forKey: AgentSidebarDefaults.showGitBranch)
            || defaults.bool(forKey: AgentSidebarDefaults.showGitChanges)
        let wantChanges = defaults.bool(forKey: AgentSidebarDefaults.showGitChanges)
        let hooks = AgentHookStore.load()

        let chrome = currentChrome()
        if chrome != self.chrome {
            self.chrome = chrome
        }

        var result: [Tab] = []
        var liveWindows: [ObjectIdentifier: WeakWindow] = [:]
        var seenGroups = Set<ObjectIdentifier>()

        for window in NSApp.windows {
            guard window.windowController is TerminalController else { continue }

            let groupID = Self.groupID(for: window)
            guard seenGroups.insert(groupID).inserted else { continue }

            // A window without tabs still has a tab group, but that group's
            // window list is empty and it has no selected window.
            var groupWindows = window.tabGroup?.windows ?? []
            if groupWindows.isEmpty {
                groupWindows = [window]
            }
            let selectedWindow = window.tabGroup?.selectedWindow ?? window

            for tabWindow in groupWindows {
                guard let controller = tabWindow.windowController as? TerminalController else { continue }

                let id = ObjectIdentifier(tabWindow)
                liveWindows[id] = WeakWindow(window: tabWindow)

                let surfaces = controller.surfaceTree.root?.leaves() ?? []
                let title = tabWindow.title
                let pwd = controller.focusedSurface?.pwd ?? surfaces.first?.pwd
                let agent = agentInfo(surfaces: surfaces, title: title, hooks: hooks)
                // With one pane the sidebar already says where the agent is.
                let ring = surfaces.count > 1 && defaults.bool(forKey: AgentSidebarDefaults.paneRing)
                for surface in surfaces {
                    AgentPaneRing.sync(surface, show: ring && agent.waiting.contains { $0 === surface })
                }
                var git: AgentGitInfo?
                if wantGit, let pwd {
                    git = gitInfo(path: pwd, includeChanges: wantChanges)
                }

                result.append(Tab(
                    id: id,
                    groupID: groupID,
                    stableID: AgentControlOperations.stableTabID(controller),
                    title: title,
                    pwd: pwd,
                    isSelected: tabWindow === selectedWindow,
                    hasBell: controller.bell,
                    agent: agent.kind,
                    state: agent.state,
                    message: agent.message,
                    sessionID: agent.sessionID,
                    sessionCwd: agent.sessionCwd,
                    usage: agent.kind == .claude
                        ? agent.sessionID.flatMap { AgentUsageTracker.shared.usage(for: $0) } : nil,
                    layout: surfaces.count > 1
                        ? controller.surfaceTree.root.map { paneLayout($0, hooks: hooks) } : nil,
                    git: git
                ))
            }
        }

        windows = liveWindows
        if AgentSidebarDemo.enabled, let first = result.first {
            result = AgentSidebarDemo.tabs(groupID: first.groupID, realWindow: first.id)
            if recentSessions.isEmpty {
                recentSessions = AgentSidebarDemo.recentSessions
                autofix["demo-0"] = Autofix(state: "detected", paneID: "demo", summary: "Command failed (exit 127)")
            }
        }
        if !AgentSidebarDemo.enabled {
            AgentNotifier.shared.update(result) { tab in
                NSApp.isActive && tab.isSelected && (windows[tab.id]?.window?.isKeyWindow ?? false)
            }
            let unread = AgentNotifier.shared.unread
            for index in result.indices where unread.contains(result[index].stableID) {
                result[index].unread = true
            }
        }
        var labels = defaults.dictionary(forKey: AgentSidebarDefaults.shortLabels) as? [String: String] ?? [:]
        var labelsChanged = false
        for index in result.indices {
            let tab = result[index]
            let key = Self.shortLabelKey(tab)
            var label = key.flatMap { labels[$0] }
            if tab.agent == nil {
                tabLabels[tab.id] = nil
            } else if let label {
                tabLabels[tab.id] = label
            } else if let carried = tabLabels[tab.id] {
                // A new session in the same tab (after /clear) keeps the tab's label.
                label = carried
                if let key, key.hasPrefix("session:") {
                    labels[key] = carried
                    labelsChanged = true
                }
            }
            result[index].shortLabel = label
        }
        tabLabels = tabLabels.filter { liveWindows[$0.key] != nil }
        if labelsChanged {
            defaults.set(labels, forKey: AgentSidebarDefaults.shortLabels)
        }
        if result != tabs {
            tabs = result
        }
        if !AgentSidebarDemo.enabled {
            AgentFeed.shared.update(result, events: AgentNotifier.shared.events, front: AgentNotifier.shared.front)
        }
        let liveIDs = Set(result.map(\.stableID))
        if autofix.keys.contains(where: { !liveIDs.contains($0) }), !AgentSidebarDemo.enabled {
            autofix = autofix.filter { liveIDs.contains($0.key) }
        }

        applyNativeTabBarVisibility()

        if !AgentSidebarDemo.enabled, Date().timeIntervalSince(usageScanned) > 2 {
            usageScanned = Date()
            AgentUsageTracker.shared.scan(Set(tabs.filter { $0.agent == .claude }.compactMap(\.sessionID)))
        }

        if !AgentSidebarDemo.enabled {
            AgentSessionRestore.shared.update(tabs)
        }

        if defaults.bool(forKey: AgentSidebarDefaults.showRecent), !AgentSidebarDemo.enabled {
            refreshRecentSessionsIfNeeded()
        }
    }

    // MARK: Agent detection

    /// Labels the user gave to agent tabs, by tab, so they outlive the session.
    private var tabLabels: [ObjectIdentifier: String] = [:]

    /// The split tree of a tab as directories and Claude Code sessions.
    private func paneLayout(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        hooks: [String: AgentHookStatus]
    ) -> AgentSessionRestore.SavedPane {
        switch node {
        case .leaf(let view):
            var pane = AgentSessionRestore.SavedPane(cwd: view.pwd)
            guard let model = view.surfaceModel, let tty = model.ttyName,
                  let hook = hooks[(tty as NSString).lastPathComponent], (hook.agent ?? .claude) == .claude
            else { return pane }
            // A shell in front: the session that wrote the status is over.
            if let name = model.foregroundPID.flatMap({ Self.processName(pid: $0) }),
               AgentHookStore.shellNames.contains(name.lowercased()) {
                return pane
            }
            pane.session = hook.sessionID
            pane.sessionCwd = hook.cwd
            return pane
        case .split(let split):
            return AgentSessionRestore.SavedPane(
                children: [paneLayout(split.left, hooks: hooks), paneLayout(split.right, hooks: hooks)],
                horizontal: split.direction == .horizontal,
                ratio: (split.ratio * 1000).rounded() / 1000)
        }
    }

    private struct AgentInfo {
        var kind: AgentKind?
        var state: AgentState?
        var message: String?
        var sessionID: String?
        var sessionCwd: String?
        /// Panes whose agent waits for the user.
        var waiting: [Ghostty.SurfaceView] = []
    }

    /// Works out which agent (if any) runs in a tab and what it is doing.
    ///
    /// Two sources are combined per pane: the foreground process of the pty
    /// and the status file written by the agent's hooks, keyed by tty.
    private func agentInfo(
        surfaces: [Ghostty.SurfaceView],
        title: String,
        hooks: [String: AgentHookStatus]
    ) -> AgentInfo {
        var best = AgentInfo()
        var bestPriority = -1
        var waiting: [Ghostty.SurfaceView] = []

        for surface in surfaces {
            guard let surfaceModel = surface.surfaceModel else { continue }

            let processName = surfaceModel.foregroundPID.flatMap { Self.processName(pid: $0) }
            let processAgent = processName.flatMap { AgentKind.from(processName: $0) }

            var hook: AgentHookStatus?
            if let tty = surfaceModel.ttyName {
                hook = hooks[(tty as NSString).lastPathComponent]
            }
            // A shell in the foreground means the agent that wrote the status
            // file has exited without running its session-end hook.
            if let processName, AgentHookStore.shellNames.contains(processName.lowercased()) {
                hook = nil
            }

            guard let kind = hook?.agent ?? processAgent ?? (hook != nil ? AgentKind.claude : nil) else { continue }
            if hook?.state == .waiting {
                waiting.append(surface)
            }

            let priority = hook?.state.priority ?? 0
            if priority > bestPriority {
                bestPriority = priority
                best = AgentInfo(
                    kind: kind, state: hook?.state, message: hook?.message,
                    sessionID: hook?.sessionID, sessionCwd: hook?.cwd)
            }
        }

        if best.kind == nil {
            best.kind = AgentKind.from(title: title)
        }
        best.waiting = waiting
        return best
    }

    /// Name of a process as the kernel reports it (e.g. `claude`, `zsh`).
    private static func processName(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(Int32(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Git

    /// Returns cached git info and refreshes it in the background when stale.
    private func gitInfo(path: String, includeChanges: Bool) -> AgentGitInfo? {
        let now = Date()
        let entry = gitCache[path]
        let stale = entry.map { now.timeIntervalSince($0.updated) > Self.gitRefreshInterval } ?? true

        if stale && entry?.loading != true {
            gitCache[path] = GitCacheEntry(info: entry?.info, updated: entry?.updated ?? .distantPast, loading: true)
            workQueue.async {
                var info = AgentGitReader.read(path: path)
                if includeChanges, info != nil {
                    info?.changes = AgentGitReader.changeCount(path: path)
                }
                let loaded = info
                DispatchQueue.main.async {
                    Task { @MainActor in
                        AgentSidebarModel.shared.storeGitInfo(loaded, path: path)
                    }
                }
            }
        }

        return entry?.info
    }

    private func storeGitInfo(_ info: AgentGitInfo?, path: String) {
        gitCache[path] = GitCacheEntry(info: info, updated: Date(), loading: false)

        // Drop entries for directories no tab is in anymore.
        if gitCache.count > 64 {
            let live = Set(tabs.compactMap { $0.pwd })
            gitCache = gitCache.filter { live.contains($0.key) || $0.value.loading }
        }

        // Publish right away. The entry is fresh now, so this cannot start
        // another load.
        refresh()
    }

    // MARK: Recent sessions

    private func refreshRecentSessionsIfNeeded() {
        guard !recentLoading else { return }
        guard Date().timeIntervalSince(recentUpdated) > Self.recentRefreshInterval else { return }
        recentLoading = true
        workQueue.async {
            let sessions = AgentRecentSessions.scan()
            DispatchQueue.main.async {
                Task { @MainActor in
                    AgentSidebarModel.shared.storeRecentSessions(sessions)
                }
            }
        }
    }

    private func storeRecentSessions(_ sessions: [AgentRecentSession]) {
        recentLoading = false
        recentUpdated = Date()
        if sessions != recentSessions {
            recentSessions = sessions
        }
    }

    // MARK: Native tab bar

    /// Re-applies the per-window AppKit state right after a layout change.
    func syncWindowChrome() {
        applyNativeTabBarVisibility()
    }

    /// Lowercased name of the process in front in the tab's focused terminal.
    func frontProcessName(_ tab: Tab) -> String? {
        guard let controller = window(for: tab)?.windowController as? TerminalController,
              let pid = controller.focusedSurface?.surfaceModel?.foregroundPID
        else { return nil }
        return Self.processName(pid: pid)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// True when the tab's focused terminal sits at a shell prompt.
    func hasShellInFront(_ tab: Tab) -> Bool {
        frontProcessName(tab).map { AgentHookStore.shellNames.contains($0) } ?? false
    }

    /// Hides AppKit's own tab bar while the sidebar is showing the tabs.
    ///
    /// The tab bar is a titlebar accessory, and hiding an accessory view
    /// controller is public API. The accessory is found by the identifier
    /// Ghostty's window classes give it, with the private `NSTabBar` class
    /// name as a fallback. If it is not found nothing changes.
    private func applyNativeTabBarVisibility() {
        let defaults = UserDefaults.standard
        // The collapsed rail lists the tabs too.
        let hide = defaults.bool(forKey: AgentSidebarDefaults.hideNativeTabBar)

        let sidebarVisible = defaults.bool(forKey: AgentSidebarDefaults.visible)

        for entry in windows.values {
            guard let window = entry.window, window.styleMask.contains(.titled) else { continue }

            AgentSidebarTitlebarBackdrop.sync(
                window: window,
                width: sidebarVisible ? Self.occupiedWidth : nil,
                chrome: chrome)
            for accessory in window.titlebarAccessoryViewControllers {
                // Ghostty tags the tab bar accessory itself; only the main
                // window's accessory actually contains the NSTabBar view.
                let isTabBar = accessory.identifier == TerminalWindow.tabBarIdentifier
                    || accessory.view.contains(className: "NSTabBar")
                guard isTabBar else { continue }
                if accessory.isHidden != hide {
                    accessory.isHidden = hide
                }
            }
        }
    }

    // MARK: Layout

    /// Width the sidebar (or its collapsed rail) takes from a window,
    /// including the divider.
    static var occupiedWidth: CGFloat {
        _ = shared // registers the defaults
        let defaults = UserDefaults.standard
        return occupiedWidth(
            visible: defaults.bool(forKey: AgentSidebarDefaults.visible),
            width: defaults.double(forKey: AgentSidebarDefaults.width))
    }

    static func occupiedWidth(visible: Bool, width: Double) -> CGFloat {
        (visible ? clampedWidth(width) : collapsedWidth) + 1
    }

    static let collapsedWidth: CGFloat = 46

    static func clampedWidth(_ width: Double) -> CGFloat {
        CGFloat(min(max(width, 210), 480))
    }

    /// Window content size that leaves a terminal of `terminalSize` next to
    /// the sidebar. Used for the initial size of new windows.
    static func contentSize(forTerminal terminalSize: NSSize?) -> NSSize? {
        guard var size = terminalSize else { return nil }
        size.width += occupiedWidth
        return size
    }

    // MARK: Actions

    func window(for tab: Tab) -> NSWindow? {
        windows[tab.id]?.window
    }

    /// Switches to a tab.
    func select(_ tab: Tab) {
        guard let window = window(for: tab) else { return }
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// Switches to the next tab that waits for the user, starting after the
    /// tab of the key window and wrapping around.
    func selectNextNeedingAttention() {
        refresh()
        guard !tabs.isEmpty else { return }
        let keyWindow = NSApp.keyWindow
        let current = tabs.firstIndex { windows[$0.id]?.window === keyWindow } ?? -1
        for offset in 1...tabs.count {
            let tab = tabs[(current + offset) % tabs.count]
            if tab.needsAttention || tab.unread || tab.state == .error {
                select(tab)
                return
            }
        }
    }

    /// Opens the agent pane (chat with the agent) to the right of the
    /// focused terminal of `window`.
    func openAgentPane(from window: NSWindow?) {
        let controller = (window?.windowController as? TerminalController)
            ?? (NSApp.keyWindow?.windowController as? TerminalController)
        guard let surface = controller?.focusedSurface else { return }
        let command = UserDefaults.standard.string(forKey: AgentSidebarDefaults.agentPaneCommand)
            ?? AgentSidebarDefaults.defaultAgentPaneCommand
        _ = try? AgentControlOperations.perform("split_pane", [
            "target": AgentControlOperations.paneID(surface),
            "direction": "right",
            "command": command,
            "agent_pane": true,
            "focus": true,
            "wait": true,
        ])
    }

    /// The label follows the agent session, or the directory for a plain shell.
    static func shortLabelKey(_ tab: Tab) -> String? {
        if tab.agent != nil, let session = tab.sessionID, !session.isEmpty {
            return "session:" + session
        }
        if let pwd = tab.pwd, !pwd.isEmpty {
            return "dir:" + pwd
        }
        return nil
    }

    /// Asks for the letters shown under the tab's icon; empty returns to the automatic ones.
    func editShortLabel(_ tab: Tab) {
        guard let key = Self.shortLabelKey(tab), let window = window(for: tab) else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = tab.shortLabel ?? ""
        field.placeholderString = AgentSidebarMonogram(tab: tab, automatic: true).letters

        let alert = NSAlert()
        alert.messageText = "Short Label"
        alert.informativeText = "Up to \(AgentSidebarMonogram.maxLetters) characters shown under the icon in the collapsed sidebar."
            + " Leave empty for the automatic label."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let label = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(AgentSidebarMonogram.maxLetters))
            Task { @MainActor in
                var labels = UserDefaults.standard.dictionary(forKey: AgentSidebarDefaults.shortLabels) as? [String: String] ?? [:]
                labels[key] = label.isEmpty ? nil : label
                self.tabLabels[tab.id] = label.isEmpty || tab.agent == nil ? nil : label
                UserDefaults.standard.set(labels, forKey: AgentSidebarDefaults.shortLabels)
                self.refresh()
            }
        }
    }

    /// Asks for a new tab title with Ghostty's own prompt.
    func rename(_ tab: Tab) {
        guard let window = window(for: tab),
              let controller = window.windowController as? TerminalController
        else { return }
        window.makeKeyAndOrderFront(nil)
        controller.promptTabTitle()
    }

    /// Closes every other tab of the same window.
    func closeOthers(_ tab: Tab) {
        guard let window = window(for: tab),
              let controller = window.windowController as? TerminalController
        else { return }
        window.makeKeyAndOrderFront(nil)
        controller.closeOtherTabs(nil)
    }

    /// Closes a tab, with Ghostty's usual confirmation for running processes.
    func close(_ tab: Tab) {
        guard let window = window(for: tab),
              let controller = window.windowController as? TerminalController
        else { return }
        // The confirmation is a sheet on the tab's own window, so bring that
        // tab to the front first when a confirmation is going to be shown.
        if controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            window.makeKeyAndOrderFront(nil)
        }
        controller.closeTab(nil)
    }

    /// Opens a new tab next to `window`, inheriting from its focused terminal.
    func newTab(from window: NSWindow?) {
        guard let controller = window?.windowController as? TerminalController else { return }
        controller.newTab(nil)
    }

    /// Opens a new tab in the session's directory and resumes it there.
    func resume(_ session: AgentRecentSession, from window: NSWindow?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        // The id comes from a file name; allow only what a session id contains.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !session.id.isEmpty, session.id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return }

        var config = Ghostty.SurfaceConfiguration()
        if let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) {
            config.workingDirectory = cwd
        }
        config.initialInput = "claude --resume \(session.id)\n"
        _ = TerminalController.newTab(appDelegate.ghostty, from: window, withBaseConfig: config)
    }
}
