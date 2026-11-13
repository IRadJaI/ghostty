import SwiftUI

/// Tabs that work in the same repository share a color.
@MainActor
enum AgentProjects {
    struct Mark: Equatable {
        let name: String
        let color: Color
    }

    private static var cache: [String: String] = [:]
    private static var cached = Date.distantPast

    private static let hues: [Double] = [0.58, 0.08, 0.38, 0.78, 0.0, 0.48, 0.15, 0.68, 0.92, 0.28]

    /// The repository a directory belongs to (the main one for a worktree),
    /// or the directory itself outside of git.
    static func root(of path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "/" || path == home { return nil }
        if Date().timeIntervalSince(cached) > 60 {
            cache = [:]
            cached = Date()
        }
        if let known = cache[path] { return known }

        var found = path
        var directory = path
        while directory != "/", directory != home {
            let git = (directory as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git, isDirectory: &isDirectory) {
                found = directory
                if !isDirectory.boolValue,
                   let text = try? String(contentsOfFile: git, encoding: .utf8),
                   let range = text.range(of: "/.git/worktrees/"),
                   let start = text.range(of: "gitdir: ") {
                    found = String(text[start.upperBound..<range.lowerBound])
                }
                break
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        cache[path] = found
        return found
    }

    /// Marks for the projects that have more than one tab.
    static func marks(_ tabs: [AgentSidebarModel.Tab]) -> [String: Mark] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for tab in tabs {
            guard let project = tab.project else { continue }
            if counts[project] == nil { order.append(project) }
            counts[project, default: 0] += 1
        }
        var taken = Set<Int>()
        var marks: [String: Mark] = [:]
        for project in order where counts[project, default: 0] > 1 {
            // djb2: the same project gets the same color on every launch.
            var hash: UInt64 = 5381
            for byte in project.utf8 {
                hash = (hash &* 33) &+ UInt64(byte)
            }
            var index = Int(hash % UInt64(hues.count))
            if taken.count < hues.count {
                while taken.contains(index) { index = (index + 1) % hues.count }
            }
            taken.insert(index)
            marks[project] = Mark(
                name: (project as NSString).lastPathComponent,
                color: Color(hue: hues[index], saturation: 0.6, brightness: 0.85))
        }
        return marks
    }
}

/// The colored bar at the leading edge of a grouped tab.
struct AgentProjectStripe: View {
    let color: Color?

    var body: some View {
        if let color {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, -1)
        }
    }
}
