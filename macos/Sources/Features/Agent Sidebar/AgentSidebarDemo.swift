import AppKit

// Fork addition (agent-sidebar): sample content for design work.
//
// Launching the app with `GHOSTTY_AGENT_SIDEBAR_DEMO=1` fills the sidebar
// with tabs in every state, so screenshots (including the ones CI takes) do
// not depend on real agents running.
enum AgentSidebarDemo {
    static let enabled = ProcessInfo.processInfo.environment["GHOSTTY_AGENT_SIDEBAR_DEMO"] == "1"

    private static let anchors: [NSObject] = (0..<6).map { _ in NSObject() }

    @MainActor
    static func tabs(groupID: ObjectIdentifier, realWindow: ObjectIdentifier) -> [AgentSidebarModel.Tab] {
        typealias Tab = AgentSidebarModel.Tab
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func tab(
            _ index: Int,
            _ title: String,
            _ path: String,
            selected: Bool = false,
            agent: AgentKind? = nil,
            state: AgentState? = nil,
            message: String? = nil,
            branch: String? = nil,
            changes: Int? = nil
        ) -> Tab {
            Tab(
                id: index == 0 ? realWindow : ObjectIdentifier(anchors[index]),
                groupID: groupID,
                stableID: "demo-\(index)",
                title: title,
                pwd: home + path,
                isSelected: selected,
                hasBell: false,
                agent: agent,
                state: state,
                message: message,
                git: branch.map {
                    AgentGitInfo(repository: (path as NSString).lastPathComponent, branch: $0, changes: changes)
                }
            )
        }

        return [
            tab(0, "zsh", "/src/acme-web", selected: true, branch: "main"),
            tab(1, "✳ Fix checkout double charge", "/src/acme-web", agent: .claude, state: .working,
                branch: "fix/checkout", changes: 4),
            tab(2, "✳ Settings page i18n", "/src/acme-web", agent: .claude, state: .waiting,
                message: "Claude needs your permission to use Bash", branch: "feat/i18n", changes: 12),
            tab(3, "✳ Accessibility audit", "/src/design-system", agent: .claude, state: .done,
                branch: "audit"),
            tab(4, "codex", "/src/api", agent: .codex, branch: "rate-limit", changes: 2),
            tab(5, "npm run dev", "/src/docs-site"),
        ]
    }

    static var recentSessions: [AgentRecentSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let now = Date()
        return [
            AgentRecentSession(id: "demo-1", title: "Terraform upgrade plan", cwd: home + "/src/infra",
                               modified: now.addingTimeInterval(-40 * 60)),
            AgentRecentSession(id: "demo-2", title: "Backfill job for orders table", cwd: home + "/src/data-pipeline",
                               modified: now.addingTimeInterval(-5 * 3600)),
            AgentRecentSession(id: "demo-3", title: "Bundle size investigation", cwd: home + "/src/mobile-web",
                               modified: now.addingTimeInterval(-2 * 86400)),
        ]
    }
}
