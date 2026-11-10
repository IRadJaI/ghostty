import AppKit
import Darwin
import GhosttyKit

// Fork addition (agent-sidebar): a local control socket for agent tooling.
//
// External helpers (the `wtcli` backend used by the WTA agent pane) need to
// list panes, read their text, split, type into a pane and receive events
// such as "a command failed". Ghostty's AppleScript API covers part of that,
// but it cannot read terminal text and has no event stream, so the fork
// serves those operations on a Unix domain socket instead.
//
// Protocol: newline-delimited JSON, one request per connection.
//   -> {"method": "list_panes", "params": {...}}
//   <- {"ok": true, "result": ...}   or   {"ok": false, "error": "..."}
// `subscribe` keeps the connection open and streams one event per line.
//
// The socket is created with mode 0600 inside a 0700 directory, so only the
// current user can connect. Its path is exported to child processes as
// `GHOSTTY_AGENT_SOCKET`.

/// Serves the control socket. One instance for the whole app.
final class AgentControlServer {
    static let shared = AgentControlServer()

    /// Environment variable that tells child processes where the socket is.
    static let socketEnvironmentVariable = "GHOSTTY_AGENT_SOCKET"

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var subscribers: [Int32] = []
    private(set) var socketPath: String?

    private init() {}

    // MARK: Lifecycle

    /// Starts listening. Safe to call more than once.
    func start() {
        lock.lock()
        let alreadyRunning = listenFD >= 0
        lock.unlock()
        guard !alreadyRunning else { return }

        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ghostty-agent-\(getuid())")
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "ghostty"
        var path = (directory as NSString).appendingPathComponent("\(bundleID).sock")
        // sun_path holds 104 bytes; fall back to a short path if needed.
        if path.utf8.count > 100 {
            let short = "/tmp/ghostty-agent-\(getuid())"
            try? FileManager.default.createDirectory(
                atPath: short,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            path = (short as NSString).appendingPathComponent("\(bundleID).sock")
        }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied: Bool = path.withCString { source in
            guard strlen(source) < capacity else { return false }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = strcpy(destination, source)
                }
            }
            return true
        }
        guard copied else {
            close(fd)
            return
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            return
        }

        lock.lock()
        listenFD = fd
        socketPath = path
        lock.unlock()
        setenv(Self.socketEnvironmentVariable, path, 1)

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "agent-control-accept"
        thread.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            // A subscriber that went away must not kill the app on write.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "agent-control-client"
            thread.start()
        }
    }

    // MARK: Connections

    private func serve(_ fd: Int32) {
        guard let line = Self.readLine(fd),
              let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = request["method"] as? String
        else {
            Self.write(fd, ["ok": false, "error": "invalid request"])
            close(fd)
            return
        }
        let params = request["params"] as? [String: Any] ?? [:]

        if method == "subscribe" {
            lock.lock()
            subscribers.append(fd)
            lock.unlock()
            Self.write(fd, ["ok": true, "result": ["subscribed": true]])
            // Block until the peer closes; events are written by `broadcast`.
            var byte: UInt8 = 0
            while read(fd, &byte, 1) > 0 {}
            lock.lock()
            subscribers.removeAll { $0 == fd }
            lock.unlock()
            close(fd)
            return
        }

        if method == "publish" {
            if let event = params["event"] {
                broadcast(event)
                // The agent's error-fix progress drives the sidebar's bar.
                if let object = event as? [String: Any],
                   object["method"] as? String == "autofix_state",
                   let eventParams = object["params"] as? [String: Any] {
                    let state = AgentSidebarModel.Autofix(
                        state: eventParams["state"] as? String ?? "cleared",
                        paneID: eventParams["pane_id"] as? String ?? "",
                        summary: eventParams["summary"] as? String ?? ""
                    )
                    let tabID = eventParams["tab_id"] as? String
                    DispatchQueue.main.async {
                        AgentSidebarModel.shared.applyAutofix(state, tabID: tabID)
                    }
                }
            }
            Self.write(fd, ["ok": true, "result": ["ok": true]])
            close(fd)
            return
        }

        var response: [String: Any] = ["ok": false, "error": "no response"]
        DispatchQueue.main.sync {
            response = MainActor.assumeIsolated {
                do {
                    return ["ok": true, "result": try AgentControlOperations.perform(method, params)]
                } catch {
                    return ["ok": false, "error": "\(error)"]
                }
            }
        }
        Self.write(fd, response)
        close(fd)
    }

    /// Sends one event to every subscriber.
    func broadcast(_ event: Any) {
        guard JSONSerialization.isValidJSONObject(event),
              var data = try? JSONSerialization.data(withJSONObject: event)
        else { return }
        data.append(0x0A)

        lock.lock()
        let targets = subscribers
        lock.unlock()
        for fd in targets {
            Self.writeAll(fd, data)
        }
    }

    // MARK: IO helpers

    private static func readLine(_ fd: Int32, limit: Int = 4 * 1024 * 1024) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < limit {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 {
                break
            }
            if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<newline])
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }

    private static func write(_ fd: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        writeAll(fd, data)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    return
                }
                offset += written
            }
        }
    }
}

/// An error reported back to the client as `{"ok": false, "error": ...}`.
struct AgentControlError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The operations behind the socket. Everything here runs on the main thread.
@MainActor
enum AgentControlOperations {
    /// Panes that host an agent UI (the WTA helper) rather than a shell.
    private static var agentPanes = Set<UUID>()

    static func perform(_ method: String, _ params: [String: Any]) throws -> Any {
        switch method {
        case "info":
            return [
                "connected": true,
                "backend": "ghostty",
                "protocol_version": "2.4-ghostty",
                "socket": AgentControlServer.shared.socketPath ?? "",
            ]

        case "list_windows":
            return ["windows": windowGroups().enumerated().map { index, group in
                [
                    "window_id": index + 1,
                    "title": group.selected?.window?.title ?? "",
                    "is_focused": group.controllers.contains { $0.window === NSApp.keyWindow },
                    "tab_count": group.controllers.count,
                ] as [String: Any]
            }]

        case "list_tabs":
            let wanted = intParam(params, "window_id")
            var tabs: [[String: Any]] = []
            for (index, group) in windowGroups().enumerated() where wanted == nil || wanted == index + 1 {
                for (tabIndex, controller) in group.controllers.enumerated() {
                    tabs.append([
                        "tab_id": tabNumber(windowIndex: index, tabIndex: tabIndex),
                        "stable_id": stableTabID(controller),
                        "window_id": index + 1,
                        "title": controller.window?.title ?? "",
                        "is_active": controller === group.selected,
                        "pane_count": surfaces(of: controller).count,
                    ])
                }
            }
            return ["tabs": tabs]

        case "list_panes":
            let wantedWindow = intParam(params, "window_id")
            let wantedTab = intParam(params, "tab_id")
            var panes: [[String: Any]] = []
            for (index, group) in windowGroups().enumerated() where wantedWindow == nil || wantedWindow == index + 1 {
                for (tabIndex, controller) in group.controllers.enumerated() {
                    let number = tabNumber(windowIndex: index, tabIndex: tabIndex)
                    if let wantedTab, wantedTab != number {
                        continue
                    }
                    for surface in surfaces(of: controller) {
                        panes.append(paneInfo(surface, controller: controller, windowID: index + 1, tabID: number))
                    }
                }
            }
            return ["panes": panes]

        case "active_pane":
            let (surface, controller) = try resolve(nil, preferShell: false)
            return describe(surface, controller)

        case "pane_info":
            let (surface, controller) = try resolve(stringParam(params, "target"), preferShell: false)
            return describe(surface, controller)

        case "pane_by_tty":
            guard let tty = stringParam(params, "tty") else { throw AgentControlError("missing tty") }
            let name = (tty as NSString).lastPathComponent
            for controller in TerminalController.all {
                for surface in surfaces(of: controller) {
                    if let surfaceTTY = surface.surfaceModel?.ttyName,
                       (surfaceTTY as NSString).lastPathComponent == name {
                        return describe(surface, controller)
                    }
                }
            }
            throw AgentControlError("no pane uses tty \(tty)")

        case "mark_agent_pane":
            let (surface, _) = try resolve(stringParam(params, "target"), preferShell: false)
            agentPanes.insert(surface.id)
            return ["ok": true, "session_id": paneID(surface)]

        case "capture_pane":
            let (surface, _) = try resolve(stringParam(params, "target"), preferShell: true)
            let maxLines = intParam(params, "max_lines") ?? 200
            let (content, lineCount, truncated) = tail(of: surface, maxLines: maxLines, maxChars: nil)
            return [
                "session_id": paneID(surface),
                "content": content,
                "line_count": lineCount,
                "truncated": truncated,
                "has_marks": false,
            ]

        case "pane_context":
            let (surface, controller) = try resolve(stringParam(params, "target"), preferShell: true)
            let maxLines = intParam(params, "max_lines") ?? 30
            let maxChars = intParam(params, "max_chars") ?? 4000
            let (content, lineCount, truncated) = tail(of: surface, maxLines: maxLines, maxChars: maxChars)
            var pane = describe(surface, controller)
            pane["is_background_tab"] = !(controller.window?.isKeyWindow ?? false)
            return [
                "pane": pane,
                "content": content,
                "output_source": content.isEmpty ? "metadata_only" : "buffer_tail",
                "fallback_reason": "ghostty_buffer_tail",
                "line_count": lineCount,
                "truncated": truncated,
                "has_marks": false,
            ]

        case "pane_status":
            guard let target = stringParam(params, "target") else { throw AgentControlError("missing target") }
            if let (surface, _) = try? resolve(target, preferShell: false) {
                return [
                    "session_id": paneID(surface),
                    "state": "running",
                    "pid": surface.surfaceModel?.foregroundPID ?? 0,
                    "has_exit_code": false,
                ]
            }
            return ["session_id": target, "state": "exited", "pid": 0, "has_exit_code": false]

        case "send_text":
            let (surface, _) = try resolve(stringParam(params, "target"), preferShell: true)
            guard let text = params["text"] as? String else { throw AgentControlError("missing text") }
            guard let model = surface.surfaceModel else { throw AgentControlError("pane has no terminal") }
            model.sendText(text)
            return ["ok": true, "session_id": paneID(surface)]

        case "focus_pane":
            let (surface, controller) = try resolve(stringParam(params, "target"), preferShell: false)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.focusSurface(surface)
            return ["ok": true, "session_id": paneID(surface)]

        case "kill_pane":
            let (surface, controller) = try resolve(stringParam(params, "target"), preferShell: false)
            let id = paneID(surface)
            agentPanes.remove(surface.id)
            controller.closeSurface(surface, withConfirmation: false)
            return ["ok": true, "session_id": id]

        case "split_pane":
            let (surface, controller) = try resolve(stringParam(params, "target"), preferShell: true)
            let direction: SplitTree<Ghostty.SurfaceView>.NewDirection
            switch (stringParam(params, "direction") ?? "auto").lowercased() {
            case "left": direction = .left
            case "up": direction = .up
            case "down", "horizontal": direction = .down
            case "right", "vertical": direction = .right
            default:
                direction = surface.bounds.width >= surface.bounds.height * 1.6 ? .right : .down
            }
            let previous = controller.focusedSurface
            guard let created = controller.newSplit(
                at: surface,
                direction: direction,
                baseConfig: configuration(params, inheritFrom: surface)
            ) else { throw AgentControlError("failed to create split") }
            if boolParam(params, "agent_pane") {
                agentPanes.insert(created.id)
            }
            // Like Windows Terminal's protocol, a split does not take focus
            // unless the caller asks for it.
            if !boolParam(params, "focus"), let previous {
                controller.focusSurface(previous)
            }
            return creationResult(created, controller)

        case "snapshot_window":
            // Renders a window of this app to a PNG, for checking the UI
            // without screen recording permission.
            let visible = NSApp.windows.filter { $0.isVisible }
            let title = stringParam(params, "title")
            let match = title.flatMap { title in visible.first { $0.title.contains(title) } }
            guard let window = match ?? (title == nil ? (NSApp.keyWindow ?? NSApp.mainWindow ?? visible.first) : nil),
                  let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { throw AgentControlError("no window to snapshot") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw AgentControlError("failed to encode the snapshot")
            }
            let path = stringParam(params, "path")
                ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("ghostty-agent-snapshot.png")
            try data.write(to: URL(fileURLWithPath: path))
            return ["ok": true, "path": path, "title": window.title]

        case "new_tab":
            guard let appDelegate = NSApp.delegate as? AppDelegate else {
                throw AgentControlError("app delegate unavailable")
            }
            let parent = TerminalController.preferredParent?.window
            let previousKey = NSApp.keyWindow
            guard let controller = TerminalController.newTab(
                appDelegate.ghostty,
                from: parent,
                withBaseConfig: configuration(params, inheritFrom: nil)
            ) else { throw AgentControlError("failed to create tab") }
            if let title = stringParam(params, "title"), !title.isEmpty {
                controller.titleOverride = title
            }
            if boolParam(params, "background"), let previousKey {
                previousKey.makeKeyAndOrderFront(nil)
            }
            guard let surface = controller.focusedSurface ?? surfaces(of: controller).first else {
                throw AgentControlError("new tab has no terminal")
            }
            return creationResult(surface, controller)

        default:
            throw AgentControlError("unsupported method '\(method)'")
        }
    }

    // MARK: Events

    /// Called when the shell reports that a command finished (OSC 133;D).
    /// Mirrors the `vt_sequence` event Windows Terminal publishes, which is
    /// what the agent's error detection listens for.
    static func commandFinished(surface: Ghostty.SurfaceView, exitCode: Int) {
        guard exitCode >= 0 else { return }
        var params: [String: Any] = [
            "pane_id": paneID(surface),
            "sequence": "osc:133;D;\(exitCode)",
        ]
        if let controller = BaseTerminalController.controller(owning: surface) {
            params["tab_id"] = stableTabID(controller)
        }
        AgentControlServer.shared.broadcast(["type": "event", "method": "vt_sequence", "params": params])
    }

    /// True when the pane hosts an agent UI instead of a shell.
    static func isAgentPane(_ surface: Ghostty.SurfaceView) -> Bool {
        agentPanes.contains(surface.id)
    }

    // MARK: Identity

    static func paneID(_ surface: Ghostty.SurfaceView) -> String {
        surface.id.uuidString.lowercased()
    }

    /// Stable identifier of a tab: the WTA helper is told this as its owner
    /// tab, and events carry it so they reach the right helper.
    static func stableTabID(_ controller: BaseTerminalController) -> String {
        guard let window = controller.window else { return "tab-detached" }
        return "tab-\(UInt(bitPattern: ObjectIdentifier(window).hashValue))"
    }

    private static func tabNumber(windowIndex: Int, tabIndex: Int) -> Int {
        (windowIndex + 1) * 1000 + tabIndex + 1
    }

    // MARK: Lookup

    private struct WindowGroup {
        var controllers: [TerminalController]
        var selected: TerminalController?
    }

    /// Terminal windows grouped the way the user sees them: one entry per
    /// native window, each holding its tabs.
    private static func windowGroups() -> [WindowGroup] {
        var groups: [WindowGroup] = []
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalController else { continue }
            let key = window.tabGroup.map { ObjectIdentifier($0) } ?? ObjectIdentifier(window)
            guard seen.insert(key).inserted else { continue }

            var controllers = (window.tabGroup?.windows ?? []).compactMap {
                $0.windowController as? TerminalController
            }
            if controllers.isEmpty {
                controllers = [controller]
            }
            let selected = window.tabGroup?.selectedWindow?.windowController as? TerminalController
            groups.append(WindowGroup(controllers: controllers, selected: selected ?? controller))
        }
        return groups
    }

    private static func surfaces(of controller: BaseTerminalController) -> [Ghostty.SurfaceView] {
        controller.surfaceTree.root?.leaves() ?? []
    }

    /// Finds a pane by id, or the pane the user is looking at.
    ///
    /// With `preferShell`, an untargeted request never resolves to an agent
    /// pane: when the user types in the agent pane, "the current shell" is
    /// its neighbour.
    private static func resolve(
        _ target: String?,
        preferShell: Bool
    ) throws -> (Ghostty.SurfaceView, BaseTerminalController) {
        if let target, !target.trimmingCharacters(in: .whitespaces).isEmpty {
            let wanted = target.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).lowercased()
            for controller in TerminalController.all {
                for surface in surfaces(of: controller) where paneID(surface) == wanted {
                    return (surface, controller)
                }
            }
            throw AgentControlError("pane \(target) not found")
        }

        let controller = (NSApp.keyWindow?.windowController as? TerminalController)
            ?? TerminalController.preferredParent
            ?? TerminalController.all.first
        guard let controller else { throw AgentControlError("no terminal window") }
        let all = surfaces(of: controller)
        guard let focused = controller.focusedSurface ?? all.first else {
            throw AgentControlError("no active pane")
        }
        if preferShell, agentPanes.contains(focused.id) {
            guard let shell = all.first(where: { !agentPanes.contains($0.id) }) else {
                throw AgentControlError("no shell pane next to the agent pane")
            }
            return (shell, controller)
        }
        return (focused, controller)
    }

    // MARK: Descriptions

    private static func describe(
        _ surface: Ghostty.SurfaceView,
        _ controller: BaseTerminalController
    ) -> [String: Any] {
        let groups = windowGroups()
        for (index, group) in groups.enumerated() {
            if let tabIndex = group.controllers.firstIndex(where: { $0 === controller }) {
                return paneInfo(
                    surface,
                    controller: controller,
                    windowID: index + 1,
                    tabID: tabNumber(windowIndex: index, tabIndex: tabIndex)
                )
            }
        }
        return paneInfo(surface, controller: controller, windowID: 0, tabID: 0)
    }

    private static func creationResult(
        _ surface: Ghostty.SurfaceView,
        _ controller: BaseTerminalController
    ) -> [String: Any] {
        let info = describe(surface, controller)
        return [
            "tab_id": info["tab_id"] ?? 0,
            "session_id": paneID(surface),
            "window_id": info["window_id"] ?? 0,
            "pid": 0,
            "stable_tab_id": stableTabID(controller),
        ]
    }

    private static func paneInfo(
        _ surface: Ghostty.SurfaceView,
        controller: BaseTerminalController,
        windowID: Int,
        tabID: Int
    ) -> [String: Any] {
        let isAgent = agentPanes.contains(surface.id)
        let size = surface.surfaceSize
        let shell = (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?.lastPathComponent ?? "zsh"
        return [
            "session_id": paneID(surface),
            "tab_id": tabID,
            "stable_tab_id": stableTabID(controller),
            "window_id": windowID,
            "title": surface.title,
            "profile": "",
            "is_active": controller.focusedSurface === surface && (controller.window?.isKeyWindow ?? false),
            "is_agent_pane": isAgent,
            "native_agent_provider_id": "",
            "pid": surface.surfaceModel?.foregroundPID ?? 0,
            "size": [
                "rows": Int(size?.rows ?? 0),
                "columns": Int(size?.columns ?? 0),
            ],
            "cwd": surface.pwd ?? "",
            "shell": isAgent ? "" : shell,
            "shell_version": "",
            "tty": surface.surfaceModel?.ttyName ?? "",
        ]
    }

    // MARK: Text

    /// The last lines of a pane's screen and scrollback.
    private static func tail(
        of surface: Ghostty.SurfaceView,
        maxLines: Int,
        maxChars: Int?
    ) -> (String, Int, Bool) {
        let text = surface.cachedScreenContents.get()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        var truncated = false
        let limit = max(1, maxLines)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
            truncated = true
        }
        var content = lines.joined(separator: "\n")
        if let maxChars, content.count > maxChars {
            content = String(content.suffix(max(0, maxChars)))
            truncated = true
        }
        return (content, lines.count, truncated)
    }

    // MARK: Parameters

    private static func configuration(
        _ params: [String: Any],
        inheritFrom surface: Ghostty.SurfaceView?
    ) -> Ghostty.SurfaceConfiguration? {
        let command = stringParam(params, "command")?.trimmingCharacters(in: .whitespaces) ?? ""
        let cwd = stringParam(params, "cwd") ?? surface?.pwd
        let environment = params["env"] as? [String: String] ?? [:]
        if command.isEmpty, cwd == nil, environment.isEmpty {
            return nil
        }

        var config = Ghostty.SurfaceConfiguration()
        if let cwd, !cwd.isEmpty {
            config.workingDirectory = cwd
        }
        if !command.isEmpty {
            config.command = command
            config.waitAfterCommand = boolParam(params, "wait")
        }
        for (key, value) in environment {
            config.environmentVariables[key] = value
        }
        return config
    }

    private static func stringParam(_ params: [String: Any], _ key: String) -> String? {
        if let value = params[key] as? String {
            return value
        }
        if let value = params[key] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func intParam(_ params: [String: Any], _ key: String) -> Int? {
        if let value = params[key] as? NSNumber {
            return value.intValue
        }
        if let value = params[key] as? String {
            return Int(value)
        }
        return nil
    }

    private static func boolParam(_ params: [String: Any], _ key: String) -> Bool {
        (params[key] as? NSNumber)?.boolValue ?? false
    }
}
