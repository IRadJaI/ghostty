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
            if visible {
                AgentSidebarView(windowProvider: windowProvider)
                    .frame(width: AgentSidebarModel.clampedWidth(width))
                AgentSidebarResizeHandle(width: $width)
            } else {
                AgentSidebarRail()
                Divider()
            }
            content
        }
    }
}

/// The divider between the sidebar and the terminal; drag it to resize.
private struct AgentSidebarResizeHandle: View {
    @Binding var width: Double
    @State private var widthAtDragStart: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = widthAtDragStart ?? width
                                widthAtDragStart = start
                                width = Double(AgentSidebarModel.clampedWidth(start + Double(value.translation.width)))
                            }
                            .onEnded { _ in
                                widthAtDragStart = nil
                            }
                    )
                    .help("Drag to resize the sidebar")
            }
    }
}

/// The thin strip shown while the sidebar is collapsed.
private struct AgentSidebarRail: View {
    @AppStorage(AgentSidebarDefaults.visible) private var visible = true

    var body: some View {
        VStack {
            Button {
                visible = true
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help("Show tab sidebar")
            .accessibilityLabel("Show tab sidebar")
            .padding(.top, 10)
            Spacer()
        }
        .frame(width: AgentSidebarModel.collapsedWidth)
        .frame(maxHeight: .infinity)
        .background { AgentSidebarBackground().ignoresSafeArea(.container, edges: .top) }
    }
}

/// The sidebar itself.
struct AgentSidebarView: View {
    let windowProvider: () -> NSWindow?

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

    var body: some View {
        VStack(spacing: 0) {
            header
            if searching {
                searchField
            }
            Divider()
            if AgentSidebarDemo.enabled, model.tabs.isEmpty {
                Text(model.debugInfo.isEmpty ? "no refresh yet" : model.debugInfo)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleTabs) { tab in
                        AgentSidebarRow(
                            tab: tab,
                            options: rowOptions,
                            select: { model.select(tab) },
                            close: { model.close(tab) }
                        )
                        .contextMenu {
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
        }
        .background { AgentSidebarBackground().ignoresSafeArea(.container, edges: .top) }
        .onAppear { model.start() }
        .onChange(of: hideNativeTabBar) { _ in model.refresh() }
        .onChange(of: showRecent) { _ in model.refresh() }
        .onChange(of: showGitRepo) { _ in model.refresh() }
        .onChange(of: showGitBranch) { _ in model.refresh() }
        .onChange(of: showGitChanges) { _ in model.refresh() }
    }

    // MARK: Data

    /// The tabs of the window this sidebar lives in, after filters.
    private var visibleTabs: [AgentSidebarModel.Tab] {
        var tabs = model.tabs
        if let window = windowProvider() {
            let groupID = AgentSidebarModel.groupID(for: window)
            let own = tabs.filter { $0.groupID == groupID }
            // Right after a window is created AppKit may not have put it in
            // its tab group yet; show everything rather than an empty list.
            if !own.isEmpty {
                tabs = own
            }
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
            .help("Hide tab sidebar")
            .accessibilityLabel("Hide tab sidebar")

            Text("Tabs")
                .font(.headline)

            Spacer(minLength: 4)

            Button {
                model.newTab(from: windowProvider())
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New tab")
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
            .help("Search tabs")
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
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sidebar options")
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

// MARK: - Tab row

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
                Text(tab.title.isEmpty ? "Terminal" : tab.title)
                    .font(.callout.weight(tab.isSelected ? .semibold : .regular))
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
                .help("Close tab")
                .accessibilityLabel("Close tab")
            } else if tab.needsAttention {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .accessibilityLabel("Needs attention")
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
        .help("Resume this session in a new tab")
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
