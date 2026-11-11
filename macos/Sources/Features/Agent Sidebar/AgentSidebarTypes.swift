import Foundation

// Fork addition (agent-sidebar): data types and parsing for the agent sidebar.
//
// Everything in this file is Foundation-only on purpose: no AppKit, no
// GhosttyKit. The sidebar UI lives in AgentSidebarView.swift and the glue to
// Ghostty's windows lives in AgentSidebarModel.swift.

/// UserDefaults keys for the sidebar. The defaults are registered by
/// `AgentSidebarModel` and must match the `@AppStorage` fallbacks in the views.
enum AgentSidebarDefaults {
    // No dots in the keys: SwiftUI observes them through KVO, where a dot
    // is a key path separator.
    static let visible = "AgentSidebarVisible"
    static let width = "AgentSidebarWidth"
    static let agentsOnly = "AgentSidebarAgentsOnly"
    static let showRecent = "AgentSidebarShowRecentSessions"
    static let showStatus = "AgentSidebarShowAgentStatus"
    static let showCwd = "AgentSidebarShowWorkingDirectory"
    static let showGitRepo = "AgentSidebarShowGitRepository"
    static let showGitBranch = "AgentSidebarShowGitBranch"
    static let showGitChanges = "AgentSidebarShowGitChanges"
    static let hideNativeTabBar = "AgentSidebarHideNativeTabBar"
    static let agentPaneCommand = "AgentSidebarAgentPaneCommand"
    static let notifyWaiting = "AgentSidebarNotifyWaiting"
    static let notifyDone = "AgentSidebarNotifyDone"
    /// System sound names; empty for silence.
    static let soundWaiting = "AgentSidebarSoundWaiting"
    static let soundDone = "AgentSidebarSoundDone"
    static let dockBadge = "AgentSidebarDockBadge"
    static let paneRing = "AgentSidebarPaneRing"
    /// `ask`, `always` or `never`.
    static let restoreMode = "AgentSidebarRestoreMode"
    static let statusBar = "AgentSidebarStatusBar"
    static let peekOnHover = "AgentSidebarPeekOnHover"
    /// `daily`, `weekly`, `monthly` or `never`.
    static let upstreamInterval = "AgentSidebarUpstreamInterval"
    static let upstreamLastCheck = "AgentSidebarUpstreamLastCheck"
    static let upstreamLatest = "AgentSidebarUpstreamLatest"
    static let upstreamNotified = "AgentSidebarUpstreamNotified"

    /// Claude Code itself, in an interactive login shell so `claude` is
    /// found on the user's PATH.
    static let defaultAgentPaneCommand = "/bin/zsh -lic 'exec claude'"

    /// The WTA helper (chat with the agent, error fixes) from AgentTerm.
    static let wtaAgentPaneCommand = "/bin/zsh -lc 'exec wta-ghostty helper'"

    static let registration: [String: Any] = [
        visible: true,
        width: 240.0,
        agentsOnly: false,
        showRecent: true,
        showStatus: true,
        showCwd: true,
        showGitRepo: false,
        showGitBranch: true,
        showGitChanges: false,
        hideNativeTabBar: true,
        notifyWaiting: true,
        notifyDone: true,
        soundWaiting: "Ping",
        soundDone: "Glass",
        dockBadge: true,
        paneRing: true,
        restoreMode: "ask",
        statusBar: true,
        peekOnHover: true,
        upstreamInterval: "weekly",
    ]
}

/// A coding agent CLI we know how to recognize.
enum AgentKind: String, CaseIterable {
    case claude
    case codex
    case gemini
    case copilot
    case opencode
    case aider

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .opencode: return "OpenCode"
        case .aider: return "Aider"
        }
    }

    /// Recognize an agent from the name of the terminal's foreground process.
    static func from(processName: String) -> AgentKind? {
        let name = processName.lowercased()
        for kind in AgentKind.allCases {
            if name == kind.rawValue || name.hasPrefix(kind.rawValue + "-") {
                return kind
            }
        }
        return nil
    }

    /// Recognize an agent from the terminal title. Claude Code sets its title
    /// to "✳ <task>"; other agents are matched when the title is their name.
    static func from(title: String) -> AgentKind? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("✳") {
            return .claude
        }
        let lower = trimmed.lowercased()
        for kind in AgentKind.allCases {
            if lower == kind.rawValue || lower.hasPrefix(kind.rawValue + " ") {
                return kind
            }
        }
        return nil
    }
}

/// What an agent is doing, as reported by its hooks.
enum AgentState: String {
    /// The agent is running a turn.
    case working
    /// The agent is blocked on the user (permission prompt or a question).
    case waiting
    /// The turn ended, but background shells, subagents or wake-ups are pending.
    case background
    /// The agent finished its turn.
    case done
    /// A session exists but nothing has been asked yet.
    case idle

    /// Higher means more important when several panes share one tab.
    var priority: Int {
        switch self {
        case .waiting: return 5
        case .working: return 4
        case .background: return 3
        case .done: return 2
        case .idle: return 1
        }
    }

    var label: String {
        switch self {
        case .working: return "Working…"
        case .waiting: return "Needs you"
        case .background: return "Background work"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
}

/// One status file written by `agent-sidebar/ghostty-agent-hook`.
struct AgentHookStatus: Equatable {
    var agent: AgentKind?
    var state: AgentState
    var timestamp: Date
    var sessionID: String?
    var cwd: String?
    var message: String?

    /// Parses the JSON object the hook script writes:
    /// `{"agent":"claude","state":"waiting","ts":1731182000,"tty":"ttys003","payload":{...}}`
    /// where `payload` is the hook input the agent passed on stdin (or null).
    static func parse(_ data: Data) -> AgentHookStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let stateName = root["state"] as? String,
              let state = AgentState(rawValue: stateName)
        else { return nil }

        let seconds = (root["ts"] as? NSNumber)?.doubleValue ?? 0
        let payload = root["payload"] as? [String: Any]
        // Claude Code also notifies about things that need no answer.
        var shown = state
        if state == .waiting, let type = payload?["notification_type"] as? String,
           ["idle_prompt", "auth_success", "agent_completed"].contains(type) || type.hasPrefix("quota_") {
            shown = .done
        }
        // A finished turn with work still in flight is not "done" yet.
        var message = payload?["message"] as? String
        if shown == .done {
            let pending = pendingWork(payload)
            if let work = pending.work {
                shown = .background
                message = work
            } else {
                message = pending.watching.map { "Done · " + $0 }
            }
        }
        return AgentHookStatus(
            agent: (root["agent"] as? String).flatMap { AgentKind(rawValue: $0) },
            state: shown,
            timestamp: Date(timeIntervalSince1970: seconds),
            sessionID: payload?["session_id"] as? String,
            cwd: payload?["cwd"] as? String,
            message: message
        )
    }

    /// What a finished turn left behind, from the Stop hook's `background_tasks` and `session_crons`.
    /// Work is something that will finish; a monitor or a scheduled wake-up only watches.
    private static func pendingWork(_ payload: [String: Any]?) -> (work: String?, watching: String?) {
        // Artifact subscriptions are re-armed on every resume and mean nothing to the user.
        let tasks = (payload?["background_tasks"] as? [[String: Any]] ?? []).filter {
            !(($0["description"] as? String)?.hasPrefix("live updates for artifact") ?? false)
        }
        func summary(_ types: [String]) -> String? {
            var counts: [(type: String, count: Int)] = []
            for type in types {
                if let index = counts.firstIndex(where: { $0.type == type }) {
                    counts[index].count += 1
                } else {
                    counts.append((type, 1))
                }
            }
            guard !counts.isEmpty else { return nil }
            return counts.map { "\($0.count) \($0.type)\($0.count == 1 ? "" : "s")" }.joined(separator: ", ")
        }
        let types = tasks.map { $0["type"] as? String ?? "task" }
        let work = summary(types.filter { $0 != "monitor" }).map { "Waiting for " + $0 }
        var watching = summary(types.filter { $0 == "monitor" })
        if watching == nil, !(payload?["session_crons"] as? [[String: Any]] ?? []).isEmpty {
            watching = "scheduled wake-up"
        }
        return (work, watching)
    }
}

/// Reads the status directory shared with the hook script.
enum AgentHookStore {
    /// Foreground process names that mean "no agent is running here anymore".
    static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "pwsh", "login", "xonsh", "elvish",
    ]

    /// Status files larger than this are ignored (a hook payload is tiny).
    private static let maxFileSize = 256 * 1024

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["GHOSTTY_AGENTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("status")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostty-agents")
            .appendingPathComponent("status")
    }

    /// Returns hook statuses keyed by tty name without `/dev/` (e.g. `ttys003`).
    static func load(from directory: URL = AgentHookStore.directory) -> [String: AgentHookStatus] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [:] }

        var result: [String: AgentHookStatus] = [:]
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.intValue > maxFileSize {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let status = AgentHookStatus.parse(data)
            else { continue }
            result[String(name.dropLast(".json".count))] = status
        }
        return result
    }
}

/// Git metadata for a working directory.
struct AgentGitInfo: Equatable {
    var repository: String
    var branch: String?
    var changes: Int?
}

enum AgentGitReader {
    /// Reads the repository name and branch by walking up from `path` to the
    /// nearest `.git`. This spawns no processes.
    static func read(path: String) -> AgentGitInfo? {
        let manager = FileManager.default
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<64 {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDirectory = isDirectory.boolValue ? dotGit : linkedGitDirectory(dotGit, relativeTo: directory)
                let head = gitDirectory.flatMap { try? String(contentsOf: $0.appendingPathComponent("HEAD"), encoding: .utf8) }
                return AgentGitInfo(
                    repository: directory.lastPathComponent,
                    branch: head.flatMap(branch(fromHead:)),
                    changes: nil
                )
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }
        return nil
    }

    /// `.git` is a file in worktrees and submodules: `gitdir: <path>`.
    private static func linkedGitDirectory(_ file: URL, relativeTo directory: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target)
        }
        return directory.appendingPathComponent(target).standardizedFileURL
    }

    /// `ref: refs/heads/main` -> `main`; a detached HEAD becomes a short hash.
    static func branch(fromHead head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            return nil
        }
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        if line.hasPrefix("ref: ") {
            return String(line.dropFirst("ref: ".count))
        }
        return String(line.prefix(7))
    }

    /// Counts changed files with `git status --porcelain`. Returns nil when no
    /// git binary is found; `/usr/bin/git` is deliberately not used because on
    /// a Mac without developer tools it opens an install dialog.
    static func changeCount(path: String) -> Int? {
        guard let git = gitExecutable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", path, "status", "--porcelain"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private static let gitExecutable: String? = {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
}

/// A past Claude Code session found on disk.
struct AgentRecentSession: Identifiable, Equatable {
    let id: String
    var title: String
    var cwd: String?
    var modified: Date
}

enum AgentRecentSessions {
    /// How much of a transcript is read to find its title and directory.
    private static let headBytes = 96 * 1024

    static var claudeProjects: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    /// Returns the most recently modified Claude Code transcripts.
    static func scan(directory: URL = AgentRecentSessions.claudeProjects, limit: Int = 12) -> [AgentRecentSession] {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for project in projects {
            let projectURL = directory.appendingPathComponent(project)
            guard let names = try? manager.contentsOfDirectory(atPath: projectURL.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let url = projectURL.appendingPathComponent(name)
                guard let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                else { continue }
                files.append((url, modified))
            }
        }

        files.sort { $0.modified > $1.modified }
        return files.prefix(limit).map { file in
            let head = readHead(file.url)
            let details = parseTranscriptHead(head)
            let id = file.url.deletingPathExtension().lastPathComponent
            return AgentRecentSession(
                id: id,
                title: details.title ?? "Session \(id.prefix(8))",
                cwd: details.cwd,
                modified: file.modified
            )
        }
    }

    private static func readHead(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: headBytes)
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds a title (the stored summary, else the first user prompt) and the
    /// working directory in the first lines of a transcript.
    static func parseTranscriptHead(_ text: String) -> (title: String?, cwd: String?) {
        var summary: String?
        var firstPrompt: String?
        var cwd: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let entry = object as? [String: Any]
            else { continue }

            if cwd == nil, let value = entry["cwd"] as? String {
                cwd = value
            }
            let type = entry["type"] as? String
            if type == "summary", summary == nil, let value = entry["summary"] as? String {
                summary = value
            }
            if type == "user", firstPrompt == nil, entry["isMeta"] as? Bool != true,
               let message = entry["message"] as? [String: Any] {
                firstPrompt = promptText(message["content"])
            }
            if cwd != nil, summary != nil || firstPrompt != nil {
                break
            }
        }

        let title = (summary ?? firstPrompt).map(cleanTitle)
        return (title?.isEmpty == false ? title : nil, cwd)
    }

    private static func promptText(_ content: Any?) -> String? {
        if let text = content as? String {
            return usablePrompt(text)
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String, let prompt = usablePrompt(text) {
                return prompt
            }
        }
        return nil
    }

    /// Skips slash-command and tool wrappers, which start with an XML-like tag.
    private static func usablePrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") {
            return nil
        }
        return trimmed
    }

    private static func cleanTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 80 {
            return trimmed
        }
        return String(trimmed.prefix(79)) + "…"
    }
}

enum AgentSidebarFormat {
    /// `/Users/me/src/app` -> `~/src/app`.
    static func abbreviate(path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
