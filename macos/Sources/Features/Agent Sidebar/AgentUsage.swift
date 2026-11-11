import Foundation

// Fork addition (agent-sidebar): token usage of Claude Code sessions, read from their transcripts.

struct AgentUsage: Equatable {
    /// Tokens in the context of the latest request, including its reply.
    var context = 0
    /// New input over the whole session (uncached input and cache writes).
    var input = 0
    /// Output over the whole session.
    var output = 0
    /// Input served from the prompt cache over the whole session.
    var cacheRead = 0
    var model: String?
    /// Size of the model's context window, when the status line wrapper reported it.
    var window: Int?
    /// Share of the window in use, 0...100, as Claude Code counts it.
    var percent: Double?

    var sessionTotal: Int { input + output }

    /// Reads what `ghostty-agent-statusline` saved for a session.
    static func window(session: String) -> (size: Int, percent: Double?)? {
        guard session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostty-agents/context/\(session).json")
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = root["context_window"] as? [String: Any],
              let size = (context["context_window_size"] as? NSNumber)?.intValue, size > 0
        else { return nil }
        return (size, (context["used_percentage"] as? NSNumber)?.doubleValue)
    }

    /// Status line files of sessions that are long gone.
    static func removeStaleWindows() {
        let manager = FileManager.default
        let directory = manager.homeDirectoryForCurrentUser.appendingPathComponent(".ghostty-agents/context")
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for url in (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                try? manager.removeItem(at: url)
            }
        }
    }
}

/// Follows the transcripts of the sessions it is asked about.
final class AgentUsageTracker: @unchecked Sendable {
    static let shared = AgentUsageTracker()

    private struct Session {
        var path: String?
        var offset: UInt64 = 0
        var usage = AgentUsage()
        /// A reply is written as several lines that repeat its usage.
        var lastMessageID: String?
        var lastCounted = (input: 0, output: 0, cacheRead: 0)
        var lastLookup = Date.distantPast
        var lastWanted = Date()
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var published: [String: AgentUsage] = [:]
    private var scanning = false
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.agent-usage", qos: .utility)

    /// The latest known usage of a session.
    func usage(for sessionID: String) -> AgentUsage? {
        lock.lock()
        defer { lock.unlock() }
        return published[sessionID]
    }

    /// Reads what the transcripts of these sessions gained, in the background.
    func scan(_ sessionIDs: Set<String>) {
        lock.lock()
        let busy = scanning
        if !busy {
            scanning = true
        }
        lock.unlock()
        guard !busy else { return }

        queue.async {
            for id in sessionIDs {
                self.update(id)
            }
            self.lock.lock()
            // Keep a session for a while: its id can drop out for a moment.
            let cutoff = Date().addingTimeInterval(-120)
            self.sessions = self.sessions.filter { $0.value.lastWanted > cutoff }
            self.published = self.published.filter { self.sessions[$0.key] != nil }
            self.scanning = false
            self.lock.unlock()
        }
    }

    private func update(_ id: String) {
        lock.lock()
        var session = sessions[id] ?? Session()
        lock.unlock()

        if session.path == nil {
            guard Date().timeIntervalSince(session.lastLookup) > 10 else { return }
            session.lastLookup = Date()
            session.path = Self.transcriptPath(id)
        }
        if let path = session.path, let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < session.offset {
                // The file was replaced; start over.
                session = Session(path: path)
            }
            // In blocks: a long session's transcript runs to hundreds of MB.
            while size > session.offset, (try? handle.seek(toOffset: session.offset)) != nil,
                  let data = try? handle.read(upToCount: 4 << 20), !data.isEmpty,
                  let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                let complete = data[data.startIndex...lastNewline]
                for line in complete.split(separator: UInt8(ascii: "\n")) {
                    Self.apply(line, to: &session)
                }
                session.offset += UInt64(complete.count)
            }
        }
        session.lastWanted = Date()
        if let window = AgentUsage.window(session: id) {
            session.usage.window = window.size
            // Empty right after a compaction: count from the transcript until it is back.
            session.usage.percent = window.percent
                ?? min(100, Double(session.usage.context) / Double(window.size) * 100)
        }

        lock.lock()
        sessions[id] = session
        if session.path != nil, session.usage.context > 0 {
            published[id] = session.usage
        }
        lock.unlock()
    }

    private static func apply(_ line: Data, to session: inout Session) {
        // Most lines are not replies; skip them without parsing.
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }

        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let cacheRead = count("cache_read_input_tokens")
        let input = count("input_tokens") + count("cache_creation_input_tokens")
        let output = count("output_tokens")

        let messageID = message["id"] as? String
        if let messageID, messageID == session.lastMessageID {
            session.usage.input -= session.lastCounted.input
            session.usage.output -= session.lastCounted.output
            session.usage.cacheRead -= session.lastCounted.cacheRead
        }
        session.lastMessageID = messageID
        session.lastCounted = (input, output, cacheRead)
        session.usage.input += input
        session.usage.output += output
        session.usage.cacheRead += cacheRead

        // Subagent turns have a context of their own.
        if object["isSidechain"] as? Bool != true {
            session.usage.context = input + cacheRead + output
            if let model = message["model"] as? String, !model.hasPrefix("<") {
                session.usage.model = model
            }
        }
    }

    /// Transcripts are filed by the directory the session started in.
    private static func transcriptPath(_ id: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let directories = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        for directory in directories {
            let path = projects.appendingPathComponent(directory).appendingPathComponent("\(id).jsonl").path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}

extension AgentSidebarFormat {
    /// `950`, `27k`, `1.3M`.
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return "\(Int((Double(count) / 1000).rounded()))k"
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}
