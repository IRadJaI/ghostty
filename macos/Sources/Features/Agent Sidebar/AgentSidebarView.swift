import AppKit
import SwiftUI

// Fork addition (agent-sidebar): the sidebar UI. Vertical tabs with the agent
// running in each one, its status, working directory and git metadata.

/// Wraps a terminal window's content and puts the sidebar on its leading edge.
struct AgentSidebarContainer<Content: View>: View {
    /// Returns the NSWindow hosting this view. A closure because the window
    /// does not exist yet when the view is created.
    let windowProvider: () -> NSWindow?
    let content: Content

    @AppStorage(AgentSidebarDefaults.visible) private var visible = true
    @AppStorage(AgentSidebarDefaults.width) private var width = 240.0

    init(windowProvider: @escaping () -> NSWindow?, @ViewBuilder content: () -> Content) {
        self.windowProvider = windowProvider
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            // The divider and the resize handle sit on the sidebar's own
            // backdrop; a separate divider would show the bare window.
            AgentSidebarView(windowProvider: windowProvider, compact: !visible)
                .frame(width: AgentSidebarModel.occupiedWidth(visible: visible, width: width))
                .overlay(alignment: .trailing) {
                    if visible {
                        AgentSidebarResizeHandle(width: $width)
                            .frame(width: AgentSidebarResizeHandle.hitWidth)
                    } else {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                    }
                }
            VStack(spacing: 0) {
                content
                AgentStatusBar(windowProvider: windowProvider)
            }
        }
        .onChange(of: visible) { _ in AgentSidebarModel.shared.syncWindowChrome() }
        .onChange(of: width) { _ in AgentSidebarModel.shared.syncWindowChrome() }
    }
}

/// The sidebar itself.
struct AgentSidebarView: View {
    let windowProvider: () -> NSWindow?
    /// Collapsed to a rail of tab icons.
    var compact = false

    @ObservedObject private var model = AgentSidebarModel.shared

    @AppStorage(AgentSidebarDefaults.visible) private var visible = true
    @AppStorage(AgentSidebarDefaults.agentsOnly) private var agentsOnly = false
    @AppStorage(AgentSidebarDefaults.showRecent) private var showRecent = true
    @AppStorage(AgentSidebarDefaults.showStatus) private var showStatus = true
    @AppStorage(AgentSidebarDefaults.showCwd) private var showCwd = true
    @AppStorage(AgentSidebarDefaults.showGitRepo) private var showGitRepo = false
    @AppStorage(AgentSidebarDefaults.showGitBranch) private var showGitBranch = true
    @AppStorage(AgentSidebarDefaults.showGitChanges) private var showGitChanges = false
    @AppStorage(AgentSidebarDefaults.hideNativeTabBar) private var hideNativeTabBar = true

    @State private var searching = false
    @State private var query = ""
    @State private var recentExpanded = AgentSidebarDemo.enabled
    @State private var windowID: ObjectIdentifier?

    var body: some View {
        Group {
            if compact {
                railContent
            } else {
                fullContent
            }
        }
        .background { AgentSidebarBackground() }
        .onAppear {
            resolveWindow()
            model.start()
        }
        .onReceive(model.objectWillChange) { _ in
            if windowID == nil {
                resolveWindow()
            }
        }
        .onChange(of: hideNativeTabBar) { _ in model.refresh() }
        .onChange(of: showRecent) { _ in model.refresh() }
        .onChange(of: showGitRepo) { _ in model.refresh() }
        .onChange(of: showGitBranch) { _ in model.refresh() }
        .onChange(of: showGitChanges) { _ in model.refresh() }
    }

    private var fullContent: some View {
        VStack(spacing: 0) {
            header
            if searching {
                searchField
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleTabs) { tab in
                        AgentSidebarRow(
                            tab: tab,
                            options: rowOptions,
                            select: { model.select(tab) },
                            close: { model.close(tab) }
                        )
                        .contextMenu { tabMenu(tab) }
                    }
                    if visibleTabs.isEmpty {
                        Text(agentsOnly ? "No agent tabs" : "No tabs")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    if showRecent {
                        recentSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            if let tab = ownSelectedTab, let state = model.autofix[tab.stableID] {
                Divider()
                AgentSidebarAutofixBar(state: state) { action in
                    model.sendAutofixAction(action, tabID: tab.stableID)
                }
            }
        }
    }

    /// The collapsed sidebar: one icon per tab.
    private var railContent: some View {
        VStack(spacing: 6) {
            railButton("sidebar.left", "Show tab sidebar") { visible = true }
            Divider()
                .padding(.horizontal, 8)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(Array(visibleTabs.enumerated()), id: \.element.id) { index, tab in
                        AgentSidebarRailItem(tab: tab, number: index + 1) { model.select(tab) }
                            .contextMenu { tabMenu(tab) }
                    }
                }
                .padding(.vertical, 2)
            }
            railButton("plus", "New tab") { model.newTab(from: windowProvider()) }
            railButton("sparkles", "Open agent pane") { model.openAgentPane(from: windowProvider()) }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func railButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .agentTooltip(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func tabMenu(_ tab: AgentSidebarModel.Tab) -> some View {
        Button("Rename Tab…") { model.rename(tab) }
        if let pwd = tab.pwd, !pwd.isEmpty {
            Button("Copy Working Directory") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pwd, forType: .string)
            }
        }
        Divider()
        Button("Close Tab") { model.close(tab) }
        Button("Close Other Tabs") { model.closeOthers(tab) }
    }

    // MARK: Data

    /// Remembers which window hosts this sidebar.
    ///
    /// This must not happen while `body` is evaluated: asking AppKit for the
    /// window or its tab group there re-enters SwiftUI's update and it stops
    /// updating the sidebar ("AttributeGraph: cycle detected").
    private func resolveWindow() {
        if let window = windowProvider() {
            windowID = ObjectIdentifier(window)
        }
    }

    /// The tabs of the window this sidebar lives in, after filters.
    private var visibleTabs: [AgentSidebarModel.Tab] {
        var tabs = model.tabs
        // The model already knows the tab group of every window, so `body`
        // only compares identifiers.
        if let groupID = tabs.first(where: { $0.id == windowID })?.groupID {
            tabs = tabs.filter { $0.groupID == groupID }
        }
        if agentsOnly {
            tabs = tabs.filter { $0.agent != nil }
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if searching, !needle.isEmpty {
            tabs = tabs.filter { tab in
                tab.title.lowercased().contains(needle)
                    || (tab.pwd?.lowercased().contains(needle) ?? false)
                    || (tab.git?.branch?.lowercased().contains(needle) ?? false)
            }
        }
        return tabs
    }

    /// The selected tab of the window this sidebar lives in.
    private var ownSelectedTab: AgentSidebarModel.Tab? {
        guard let groupID = model.tabs.first(where: { $0.id == windowID })?.groupID else { return nil }
        return model.tabs.first { $0.groupID == groupID && $0.isSelected }
    }

    private var rowOptions: AgentSidebarRow.Options {
        AgentSidebarRow.Options(
            showStatus: showStatus,
            showCwd: showCwd,
            showGitRepo: showGitRepo,
            showGitBranch: showGitBranch,
            showGitChanges: showGitChanges
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                visible = false
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .agentTooltip("Hide tab sidebar")
            .accessibilityLabel("Hide tab sidebar")

            Text("Tabs")
                .font(.headline)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 4)

            Button {
                model.openAgentPane(from: windowProvider())
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .agentTooltip("Open agent pane")
            .accessibilityLabel("Open agent pane")

            Button {
                model.newTab(from: windowProvider())
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .agentTooltip("New tab")
            .accessibilityLabel("New tab")

            Button {
                searching.toggle()
                if !searching {
                    query = ""
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .agentTooltip("Search tabs")
            .accessibilityLabel("Search tabs")

            optionsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var optionsMenu: some View {
        Menu {
            Section("Show") {
                Toggle("Agents only", isOn: $agentsOnly)
                Toggle("Recent agent sessions", isOn: $showRecent)
            }
            Section("Tab metadata") {
                Toggle("Agent status", isOn: $showStatus)
                Toggle("Current working directory", isOn: $showCwd)
                Toggle("Git repository", isOn: $showGitRepo)
                Toggle("Git branch", isOn: $showGitBranch)
                Toggle("Git changes", isOn: $showGitChanges)
            }
            Section("Window") {
                Toggle("Hide native tab bar", isOn: $hideNativeTabBar)
            }
            Divider()
            Button("Settings…") { AgentSettingsWindowController.shared.show() }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .agentTooltip("Sidebar options")
        .accessibilityLabel("Sidebar options")
    }

    private var searchField: some View {
        TextField("Search tabs", text: $query)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }

    // MARK: Recent sessions

    @ViewBuilder
    private var recentSection: some View {
        Button {
            recentExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: recentExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20)
                Text("Recent agent sessions")
                    .lineLimit(1)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)

        if recentExpanded {
            if model.recentSessions.isEmpty {
                Text("No Claude Code sessions found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            ForEach(model.recentSessions) { session in
                AgentSidebarSessionRow(session: session) {
                    model.resume(session, from: windowProvider())
                }
            }
        }
    }
}

/// Temporary counters for diagnosing view updates.
// MARK: - Background

/// The translucent sidebar backdrop. It blends with whatever is behind the
/// window (the desktop or other windows), like Finder's sidebar; on macOS 26
/// the system renders this material in the Liquid Glass style.
private struct AgentSidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Error-fix bar

/// Shown at the bottom of the sidebar when a command failed in the selected
/// tab and its agent pane offered to fix it.
private struct AgentSidebarAutofixBar: View {
    let state: AgentSidebarModel.Autofix
    /// Called with the event method to send to the agent pane.
    let send: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch state.state {
            case "pending":
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 18, height: 18)
                Text("Analyzing the error…")
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            case "review":
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(Color.green)
                    .frame(width: 18)
                Text("Fix ready")
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Run") { send("autofix_execute") }
                    .controlSize(.small)
                Button {
                    send("autofix_dismiss_suggestion")
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .agentTooltip("Dismiss")
                .accessibilityLabel("Dismiss fix")
            default:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.yellow)
                    .frame(width: 18)
                Text(state.summary.isEmpty ? "Command failed" : state.summary)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button("Fix") { send("autofix_execute_from_detected") }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Tab row

/// The strip under the terminal: the tab's agent, its state and the token
/// usage of its session. Hidden for tabs without an agent.
private struct AgentStatusBar: View {
    let windowProvider: () -> NSWindow?

    @ObservedObject private var model = AgentSidebarModel.shared
    @AppStorage(AgentSidebarDefaults.statusBar) private var enabled = true
    @State private var windowID: ObjectIdentifier?

    var body: some View {
        Group {
            if enabled, let tab = model.tabs.first(where: { $0.id == windowID }), let agent = tab.agent {
                HStack(spacing: 6) {
                    AgentSidebarIcon(agent: agent, state: tab.state)
                        .scaleEffect(0.8)
                    Text(agent.displayName)
                        .fontWeight(.medium)
                    if let state = tab.state {
                        Text(state.label)
                            .foregroundStyle(AgentSidebarStyle.color(for: state))
                    }
                    Spacer(minLength: 8)
                    if let usage = tab.usage {
                        metric("Context", usage.context)
                            .agentTooltip("Tokens in the context of the latest request")
                        separator
                        metric("Session", usage.sessionTotal)
                            .agentTooltip("""
                                New tokens in this session: \(AgentSidebarFormat.tokens(usage.input)) in, \
                                \(AgentSidebarFormat.tokens(usage.output)) out. \
                                Another \(AgentSidebarFormat.tokens(usage.cacheRead)) were read from the cache.
                                """)
                        if let model = usage.model {
                            separator
                            Text(model)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background { AgentSidebarBackground() }
                .overlay(alignment: .top) { Divider() }
            }
        }
        .onAppear(perform: resolveWindow)
        .onReceive(model.objectWillChange) { _ in
            if windowID == nil {
                resolveWindow()
            }
        }
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func metric(_ name: String, _ count: Int) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .foregroundStyle(.secondary)
            Text(AgentSidebarFormat.tokens(count))
                .monospacedDigit()
        }
    }

    /// Not from `body`: see `AgentSidebarView.resolveWindow`.
    private func resolveWindow() {
        if let window = windowProvider() {
            windowID = ObjectIdentifier(window)
        }
    }
}

/// A tab in the collapsed sidebar.
private struct AgentSidebarRailItem: View {
    let tab: AgentSidebarModel.Tab
    let number: Int
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            AgentSidebarIcon(agent: tab.agent, state: tab.state)
            Text("\(number)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 34, height: 38)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(tab.isSelected ? 0.16 : (hovering ? 0.07 : 0)))
        )
        .overlay(alignment: .topTrailing) {
            if tab.needsAttention || tab.unread {
                Circle()
                    .fill(tab.needsAttention ? Color.orange : AgentSidebarStyle.color(for: .done))
                    .frame(width: 7, height: 7)
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .agentTooltip(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
        .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var tooltip: String {
        var parts = [tab.title.isEmpty ? "Terminal" : tab.title]
        if let state = tab.state {
            parts.append(state.label)
        }
        if let pwd = tab.pwd, !pwd.isEmpty {
            parts.append(AgentSidebarFormat.abbreviate(path: pwd))
        }
        return parts.joined(separator: " — ")
    }
}

private struct AgentSidebarRow: View {
    struct Options: Equatable {
        var showStatus: Bool
        var showCwd: Bool
        var showGitRepo: Bool
        var showGitBranch: Bool
        var showGitChanges: Bool
    }

    let tab: AgentSidebarModel.Tab
    let options: Options
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentSidebarIcon(agent: tab.agent, state: tab.state)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.callout.weight(tab.isSelected || tab.unread ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if options.showStatus, let state = tab.state {
                    Text(statusText(state))
                        .font(.caption)
                        .foregroundStyle(AgentSidebarStyle.color(for: state))
                        .lineLimit(1)
                }
                if options.showCwd, let pwd = tab.pwd, !pwd.isEmpty {
                    Text(AgentSidebarFormat.abbreviate(path: pwd))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let gitLine {
                    Text(gitLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .agentTooltip("Close tab")
                .accessibilityLabel("Close tab")
            } else if tab.needsAttention {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .accessibilityLabel("Needs attention")
            } else if tab.unread {
                Circle()
                    .fill(AgentSidebarStyle.color(for: .done))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .accessibilityLabel("Finished, not seen yet")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(backgroundOpacity))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var backgroundOpacity: Double {
        if tab.isSelected {
            return 0.16
        }
        return hovering ? 0.07 : 0
    }

    /// The tab title without the "✳" Claude Code puts in front of it: the
    /// row already shows the agent's glyph.
    private var displayTitle: String {
        var title = tab.title.trimmingCharacters(in: .whitespaces)
        if tab.agent == .claude, title.hasPrefix("✳") {
            title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? "Terminal" : title
    }

    private func statusText(_ state: AgentState) -> String {
        if state == .waiting, let message = tab.message, !message.isEmpty {
            return message
        }
        return state.label
    }

    /// `repo · branch · ±3`, limited to the parts the user enabled.
    private var gitLine: String? {
        guard let git = tab.git else { return nil }
        var parts: [String] = []
        if options.showGitRepo {
            parts.append(git.repository)
        }
        if options.showGitBranch, let branch = git.branch {
            parts.append(branch)
        }
        if options.showGitChanges, let changes = git.changes, changes > 0 {
            parts.append("±\(changes)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Recent session row

private struct AgentSidebarSessionRow: View {
    let session: AgentRecentSession
    let open: () -> Void

    @State private var hovering = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentSidebarIcon(agent: .claude, state: nil)
                .opacity(0.6)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .agentTooltip("Resume this session in a new tab")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        let when = Self.relativeFormatter.localizedString(for: session.modified, relativeTo: Date())
        guard let cwd = session.cwd else { return when }
        return "\(AgentSidebarFormat.abbreviate(path: cwd)) · \(when)"
    }
}

// MARK: - Icon

/// The leading icon of a row: a spinner while the agent works, otherwise the
/// agent's glyph (or a terminal glyph for plain shells) with a status badge.
private struct AgentSidebarIcon: View {
    let agent: AgentKind?
    let state: AgentState?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if state == .working {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                } else if let agent {
                    glyph(for: agent)
                } else {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)

            if state == .waiting || state == .done, let state {
                Circle()
                    .fill(AgentSidebarStyle.color(for: state))
                    .frame(width: 7, height: 7)
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glyph(for agent: AgentKind) -> some View {
        switch agent {
        case .claude:
            Text("✳︎")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AgentSidebarStyle.claude)
        case .codex:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.primary)
        case .gemini:
            Image(systemName: "sparkles")
                .foregroundStyle(Color.blue)
        case .copilot:
            Image(systemName: "eyeglasses")
                .foregroundStyle(.primary)
        case .opencode, .aider:
            Image(systemName: "cpu")
                .foregroundStyle(.primary)
        }
    }
}

private enum AgentSidebarStyle {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    static func color(for state: AgentState) -> Color {
        switch state {
        case .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .idle: return .secondary
        }
    }
}
