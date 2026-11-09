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
        var title: String
        var pwd: String?
        var isSelected: Bool
        var hasBell: Bool
        var agent: AgentKind?
        var state: AgentState?
        var message: String?
        var git: AgentGitInfo?

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

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                AgentSidebarModel.shared.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
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
                var git: AgentGitInfo?
                if wantGit, let pwd {
                    git = gitInfo(path: pwd, includeChanges: wantChanges)
                }

                result.append(Tab(
                    id: id,
                    groupID: groupID,
                    title: title,
                    pwd: pwd,
                    isSelected: tabWindow === selectedWindow,
                    hasBell: controller.bell,
                    agent: agent.kind,
                    state: agent.state,
                    message: agent.message,
                    git: git
                ))
            }
        }

        windows = liveWindows
        if AgentSidebarDemo.enabled, let first = result.first {
            result = AgentSidebarDemo.tabs(groupID: first.groupID, selected: first.id)
            if recentSessions.isEmpty {
                recentSessions = AgentSidebarDemo.recentSessions
            }
        }
        if result != tabs {
            tabs = result
        }

        applyNativeTabBarVisibility()

        if defaults.bool(forKey: AgentSidebarDefaults.showRecent), !AgentSidebarDemo.enabled {
            refreshRecentSessionsIfNeeded()
        }
    }

    // MARK: Agent detection

    private struct AgentInfo {
        var kind: AgentKind?
        var state: AgentState?
        var message: String?
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

            let priority = hook?.state.priority ?? 0
            if priority > bestPriority {
                bestPriority = priority
                best = AgentInfo(kind: kind, state: hook?.state, message: hook?.message)
            }
        }

        if best.kind == nil {
            best.kind = AgentKind.from(title: title)
        }
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

    /// Hides AppKit's own tab bar while the sidebar is showing the tabs.
    ///
    /// The tab bar is a titlebar accessory, and hiding an accessory view
    /// controller is public API. The accessory is found by the identifier
    /// Ghostty's window classes give it, with the private `NSTabBar` class
    /// name as a fallback. If it is not found nothing changes.
    private func applyNativeTabBarVisibility() {
        let defaults = UserDefaults.standard
        let hide = defaults.bool(forKey: AgentSidebarDefaults.visible)
            && defaults.bool(forKey: AgentSidebarDefaults.hideNativeTabBar)

        let sidebarVisible = defaults.bool(forKey: AgentSidebarDefaults.visible)

        for entry in windows.values {
            guard let window = entry.window, window.styleMask.contains(.titled) else { continue }

            // Let the content view reach under the titlebar so the sidebar
            // backdrop can run the full height of the window, like Finder.
            // The terminal itself stays below the titlebar (safe area).
            if sidebarVisible, !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
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
        guard defaults.bool(forKey: AgentSidebarDefaults.visible) else {
            return collapsedWidth + 1
        }
        return clampedWidth(defaults.double(forKey: AgentSidebarDefaults.width)) + 1
    }

    static let collapsedWidth: CGFloat = 28

    static func clampedWidth(_ width: Double) -> CGFloat {
        CGFloat(min(max(width, 180), 480))
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
            if tab.needsAttention {
                select(tab)
                return
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
