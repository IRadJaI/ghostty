import Foundation

// Fork addition (agent-sidebar): token usage of Claude Code sessions, read
// from the transcripts Claude Code keeps under ~/.claude/projects.

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

    var sessionTotal: Int { input + output }
}

/// Follows the transcripts of the sessions it is asked about. Each file is
/// read incrementally, so a refresh costs only the lines added since.
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
            self.sessions = self.sessions.filter { sessionIDs.contains($0.key) }
            self.published = self.published.filter { sessionIDs.contains($0.key) }
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
            if size > session.offset, (try? handle.seek(toOffset: session.offset)) != nil,
               let data = try? handle.readToEnd(),
               let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                let complete = data[data.startIndex...lastNewline]
                for line in complete.split(separator: UInt8(ascii: "\n")) {
                    Self.apply(line, to: &session)
                }
                session.offset += UInt64(complete.count)
            }
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
