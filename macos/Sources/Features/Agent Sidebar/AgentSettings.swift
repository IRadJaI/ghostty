import AppKit
import GhosttyKit
import SwiftUI

// Fork addition (agent-sidebar): settings window; its values go to an overrides file, not the user config.

// MARK: - Store

/// Reads and writes the overrides file and reloads the configuration.
@MainActor
final class AgentSettingsStore: ObservableObject {
    static let shared = AgentSettingsStore()

    nonisolated static var overridesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostty-agents/settings.conf")
    }

    /// Repeatable keys: the earlier values have to be cleared first.
    private static let repeatable: Set<String> = ["font-family"]

    @Published private(set) var overrides: [String: String] = [:]
    /// Values from the user's own config files, for display only.
    private var base: [String: String] = [:]
    private var reloadWork: DispatchWorkItem?

    private init() {
        reload()
    }

    /// Loads the overrides into a configuration that is being built.
    nonisolated static func loadOverrides(into config: ghostty_config_t) {
        let path = overridesURL.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        ghostty_config_load_file(config, path)
    }

    func reload() {
        base = [:]
        for url in Self.userConfigURLs {
            base.merge(Self.parse(url)) { _, new in new }
        }
        overrides = Self.parse(Self.overridesURL)
    }

    func value(_ key: String) -> String? {
        overrides[key] ?? base[key]
    }

    func isOverridden(_ key: String) -> Bool {
        overrides[key] != nil
    }

    func set(_ key: String, _ value: String?) {
        guard overrides[key] != value else { return }
        overrides[key] = value
        write()
        scheduleConfigReload()
    }

    func resetAll() {
        overrides = [:]
        write()
        scheduleConfigReload()
    }

    private func write() {
        var lines = [
            "# Written by the Settings window. Loaded after the Ghostty config file.",
        ]
        for key in overrides.keys.sorted() {
            guard let value = overrides[key] else { continue }
            if Self.repeatable.contains(key) {
                lines.append("\(key) = \"\"")
            }
            lines.append("\(key) = \(value)")
        }
        let url = Self.overridesURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sliders produce a stream of changes; reload once they settle.
    private func scheduleConfigReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem {
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private static var userConfigURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let appSupport = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [
            xdg.appendingPathComponent("ghostty/config"),
            xdg.appendingPathComponent("ghostty/config.ghostty"),
            appSupport.appendingPathComponent("config"),
            appSupport.appendingPathComponent("config.ghostty"),
        ]
    }

    private static func parse(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if value.isEmpty {
                result[key] = nil
            } else {
                result[key] = value
            }
        }
        return result
    }

    // MARK: Choices

    /// Names of the bundled and the user's themes.
    lazy var themes: [String] = {
        var names = Set<String>()
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("ghostty/themes"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent(".config/ghostty/themes"))
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            names.formUnion(files.filter { !$0.hasPrefix(".") })
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// Families of the installed monospaced fonts.
    lazy var fonts: [String] = {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch
                ?? NSFontManager.shared.font(
                    withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch
                ?? false
        }
    }()
}

// MARK: - Window

@MainActor
final class AgentSettingsWindowController: NSWindowController {
    static let shared = AgentSettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 440)
        window.contentView = NSHostingView(rootView: AgentSettingsView())
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        AgentSettingsStore.shared.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Views

private enum AgentSettingsPane: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case behavior = "Behavior"
    case sidebar = "Sidebar"
    case agents = "Agents"
    case advanced = "Advanced"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .behavior: return "switch.2"
        case .sidebar: return "sidebar.left"
        case .agents: return "sparkles"
        case .advanced: return "gearshape.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appearance: return .blue
        case .behavior: return .green
        case .sidebar: return .indigo
        case .agents: return .orange
        case .advanced: return .gray
        }
    }
}

struct AgentSettingsView: View {
    @ObservedObject private var store = AgentSettingsStore.shared
    @AppStorage("AgentSettingsPane") private var paneName = AgentSettingsPane.appearance.rawValue

    private var pane: AgentSettingsPane? { AgentSettingsPane(rawValue: paneName) }

    private var paneBinding: Binding<AgentSettingsPane?> {
        Binding(get: { pane }, set: { paneName = ($0 ?? .appearance).rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(AgentSettingsPane.allCases, selection: paneBinding) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.vertical, 2)
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Form {
                switch pane ?? .appearance {
                case .appearance: AgentSettingsAppearance(store: store)
                case .behavior: AgentSettingsBehavior(store: store)
                case .sidebar: AgentSettingsSidebar()
                case .agents: AgentSettingsAgents()
                case .advanced: AgentSettingsAdvanced(store: store)
                }
            }
            .formStyle(.grouped)
            .navigationTitle((pane ?? .appearance).rawValue)
        }
    }
}

// MARK: Bindings

extension AgentSettingsStore {
    func text(_ key: String, default fallback: String) -> Binding<String> {
        Binding(
            get: { self.value(key) ?? fallback },
            // An empty choice means "as in the config file".
            set: { self.set(key, $0.isEmpty ? nil : $0) })
    }

    func number(_ key: String, default fallback: Double, format: String = "%.0f") -> Binding<Double> {
        Binding(
            get: { self.value(key).flatMap(Double.init) ?? fallback },
            set: { self.set(key, String(format: format, $0)) })
    }

    func flag(_ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { self.value(key).map { $0 == "true" } ?? fallback },
            set: { self.set(key, $0 ? "true" : "false") })
    }
}

// MARK: Appearance

private struct AgentSettingsAppearance: View {
    @ObservedObject var store: AgentSettingsStore
    @State private var choosingTheme = false

    private enum Blur: String, CaseIterable {
        case off = "Off"
        case blur = "Blur"
        case glassRegular = "Liquid Glass"
        case glassClear = "Liquid Glass (clear)"
    }

    var body: some View {
        Section("Colors") {
            LabeledContent("Theme") {
                Button {
                    choosingTheme = true
                } label: {
                    HStack(spacing: 4) {
                        Text(store.value("theme") ?? "Default")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                }
                .popover(isPresented: $choosingTheme, arrowEdge: .bottom) {
                    AgentSettingsThemePicker(store: store, isPresented: $choosingTheme)
                }
            }
        }

        Section("Font") {
            Picker("Family", selection: store.text("font-family", default: "")) {
                Text("From the config file").tag("")
                Divider()
                ForEach(fontChoices, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            slider("Size", store.number("font-size", default: 13), 8...32, step: 1) { "\(Int($0)) pt" }
        }

        Section {
            slider("Opacity", store.number("background-opacity", default: 1, format: "%.2f"), 0.2...1, step: 0.05) {
                "\(Int(($0 * 100).rounded()))%"
            }
            Picker("Background blur", selection: blurMode) {
                ForEach(Blur.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            if blurMode.wrappedValue == .blur {
                slider("Blur radius", blurRadius, 1...60, step: 1) { "\(Int($0))" }
            }
        } header: {
            Text("Background")
        } footer: {
            Text("Blur and Liquid Glass show through only when the opacity is below 100%.")
        }

        Section("Cursor") {
            Picker("Shape", selection: store.text("cursor-style", default: "block")) {
                Text("Block").tag("block")
                Text("Bar").tag("bar")
                Text("Underline").tag("underline")
                Text("Hollow block").tag("block_hollow")
            }
            Toggle("Blink", isOn: store.flag("cursor-style-blink", default: true))
        }

        Section {
            Picker("Titlebar", selection: store.text("macos-titlebar-style", default: "transparent")) {
                Text("Transparent").tag("transparent")
                Text("Native").tag("native")
                Text("Tabs in titlebar").tag("tabs")
                Text("Hidden").tag("hidden")
            }
            stepper("Horizontal padding", store.number("window-padding-x", default: 2))
            stepper("Vertical padding", store.number("window-padding-y", default: 2))
        } header: {
            Text("Window")
        } footer: {
            Text("The titlebar style applies to new windows.")
        }
    }

    /// The installed monospaced fonts plus the configured one.
    private var fontChoices: [String] {
        var fonts = store.fonts
        if let current = store.value("font-family"), !current.isEmpty, !fonts.contains(current) {
            fonts.insert(current, at: 0)
        }
        return fonts
    }

    private var blurMode: Binding<Blur> {
        Binding(
            get: {
                switch store.value("background-blur") ?? "false" {
                case "false", "0": return .off
                case "macos-glass-regular": return .glassRegular
                case "macos-glass-clear": return .glassClear
                default: return .blur
                }
            },
            set: { mode in
                switch mode {
                case .off: store.set("background-blur", "false")
                case .blur: store.set("background-blur", "20")
                case .glassRegular: store.set("background-blur", "macos-glass-regular")
                case .glassClear: store.set("background-blur", "macos-glass-clear")
                }
            })
    }

    private var blurRadius: Binding<Double> {
        Binding(
            get: { store.value("background-blur").flatMap(Double.init) ?? 20 },
            set: { store.set("background-blur", String(Int($0))) })
    }

    private func slider(
        _ title: String,
        _ value: Binding<Double>,
        _ range: ClosedRange<Double>,
        step: Double,
        label: @escaping (Double) -> String
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                    .frame(minWidth: 160)
                Text(label(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func stepper(_ title: String, _ value: Binding<Double>) -> some View {
        Stepper(value: value, in: 0...60, step: 1) {
            LabeledContent(title) {
                Text("\(Int(value.wrappedValue)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AgentSettingsThemePicker: View {
    @ObservedObject var store: AgentSettingsStore
    @Binding var isPresented: Bool
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollViewReader { proxy in
                List(matches, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        if name == store.value("theme") {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.set("theme", name)
                    }
                    .id(name)
                }
                .listStyle(.plain)
                .onAppear {
                    if let current = store.value("theme") {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 300, height: 380)
    }

    private var matches: [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return store.themes }
        return store.themes.filter { $0.localizedCaseInsensitiveContains(needle) }
    }
}

// MARK: Behavior

private struct AgentSettingsBehavior: View {
    @ObservedObject var store: AgentSettingsStore
    @AppStorage(AgentSidebarDefaults.restoreMode) private var restoreMode = "ask"

    var body: some View {
        Section {
            Picker("Previous tabs and Claude Code sessions", selection: $restoreMode) {
                Text("Ask to restore").tag("ask")
                Text("Restore without asking").tag("always")
                Text("Do not restore").tag("never")
            }
            Picker("Window layout and splits", selection: store.text("window-save-state", default: "default")) {
                Text("Restore only after a crash").tag("default")
                Text("Always restore").tag("always")
                Text("Never restore").tag("never")
            }
            Toggle("Quit when the last window closes",
                   isOn: store.flag("quit-after-last-window-closed", default: false))
        } header: {
            Text("Startup and quit")
        } footer: {
            Text("""
                The first option reopens the tabs in their directories and resumes the Claude Code \
                sessions that were running in them. The second is Ghostty's own restoring of windows \
                and splits; it does not restart programs.
                """)
        }

        Section("Closing") {
            Picker("Ask before closing", selection: store.text("confirm-close-surface", default: "true")) {
                Text("When a program is running").tag("true")
                Text("Always").tag("always")
                Text("Never").tag("false")
            }
        }

        Section {
            Picker("Pane drag handle", selection: store.text("drag-handle", default: "auto")) {
                Text("When the pointer is near the top").tag("auto")
                Text("Always").tag("always")
                Text("Never").tag("never")
            }
        } header: {
            Text("Splits")
        } footer: {
            Text("The three dots at the top of a pane. Drag them to rearrange splits or to move a pane to a new window.")
        }

        Section("Mouse and keyboard") {
            Picker("Copy on select", selection: store.text("copy-on-select", default: "true")) {
                Text("Off").tag("false")
                Text("To the selection clipboard").tag("true")
                Text("To the system clipboard").tag("clipboard")
            }
            Picker("Option key as Alt", selection: store.text("macos-option-as-alt", default: "false")) {
                Text("Off").tag("false")
                Text("Left Option").tag("left")
                Text("Right Option").tag("right")
                Text("Both").tag("true")
            }
            Toggle("Hide the mouse pointer while typing",
                   isOn: store.flag("mouse-hide-while-typing", default: false))
        }
    }
}

// MARK: Sidebar

private struct AgentSettingsSidebar: View {
    @AppStorage(AgentSidebarDefaults.visible) private var visible = true
    @AppStorage(AgentSidebarDefaults.agentsOnly) private var agentsOnly = false
    @AppStorage(AgentSidebarDefaults.showRecent) private var showRecent = true
    @AppStorage(AgentSidebarDefaults.showStatus) private var showStatus = true
    @AppStorage(AgentSidebarDefaults.showCwd) private var showCwd = true
    @AppStorage(AgentSidebarDefaults.showGitRepo) private var showGitRepo = false
    @AppStorage(AgentSidebarDefaults.showGitBranch) private var showGitBranch = true
    @AppStorage(AgentSidebarDefaults.showGitChanges) private var showGitChanges = false
    @AppStorage(AgentSidebarDefaults.hideNativeTabBar) private var hideNativeTabBar = true
    @AppStorage(AgentSidebarDefaults.statusBar) private var statusBar = true

    var body: some View {
        Section {
            Toggle("Show the agent status bar", isOn: $statusBar)
        } footer: {
            Text("A strip under the terminal with the agent's state, the size of its context and the tokens used by the session. Shown in tabs that run Claude Code.")
        }

        Section {
            Picker("Sidebar", selection: $visible) {
                Text("Expanded, with titles").tag(true)
                Text("Collapsed, icons only").tag(false)
            }
            Toggle("Hide the native tab bar", isOn: $hideNativeTabBar)
            Toggle("Show only tabs with agents", isOn: $agentsOnly)
            Toggle("Show recent agent sessions", isOn: $showRecent)
        } header: {
            Text("Layout")
        } footer: {
            Text("⌃⌘S toggles the sidebar, ⌃⌘G the agent filter.")
        }

        Section("Shown under each tab") {
            Toggle("Agent status", isOn: $showStatus)
            Toggle("Working directory", isOn: $showCwd)
            Toggle("Git repository", isOn: $showGitRepo)
            Toggle("Git branch", isOn: $showGitBranch)
            Toggle("Number of changed files", isOn: $showGitChanges)
        }
        .onChange(of: hideNativeTabBar) { _ in AgentSidebarModel.shared.refresh() }
        .onChange(of: showGitRepo) { _ in AgentSidebarModel.shared.refresh() }
        .onChange(of: showGitBranch) { _ in AgentSidebarModel.shared.refresh() }
        .onChange(of: showGitChanges) { _ in AgentSidebarModel.shared.refresh() }
    }
}

// MARK: Agents

private struct AgentSettingsAgents: View {
    @AppStorage(AgentSidebarDefaults.agentPaneCommand)
    private var agentPaneCommand = AgentSidebarDefaults.defaultAgentPaneCommand

    @AppStorage(AgentSidebarDefaults.notifyWaiting) private var notifyWaiting = true
    @AppStorage(AgentSidebarDefaults.notifyDone) private var notifyDone = true
    @AppStorage(AgentSidebarDefaults.notifySound) private var notifySound = true

    @State private var hooksInstalled = false
    @State private var hooksMessage: String?
    @State private var customCommand = false

    private enum Preset: Hashable {
        case claude, wta, custom
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    Label(
                        hooksInstalled ? "On" : "Off",
                        systemImage: hooksInstalled ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(hooksInstalled ? .green : .secondary)
                    Button(hooksInstalled ? "Turn Off" : "Turn On") {
                        runInstaller(remove: hooksInstalled)
                    }
                }
            } label: {
                Text("Claude Code status in the sidebar")
            }
            if let hooksMessage {
                Text(hooksMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("""
                Shows “Working”, “Needs you” and “Done” next to the tabs that run Claude Code. \
                Turning it on adds hooks to ~/.claude/settings.json (a backup copy is saved next to it) \
                and takes effect in Claude Code sessions started afterwards.
                """)
        }
        .onAppear {
            hooksInstalled = Self.detectHooks()
            customCommand = preset(for: agentPaneCommand) == .custom
        }

        Section {
            Toggle("When an agent needs you", isOn: $notifyWaiting)
            Toggle("When an agent finishes", isOn: $notifyDone)
            Toggle("Play a sound", isOn: $notifySound)
                .disabled(!notifyWaiting && !notifyDone)
        } header: {
            Text("Notifications")
        } footer: {
            Text("""
                Shown only for tabs you are not looking at; clicking one opens its tab. \
                Needs the status hooks above and notifications allowed for Ghostty in System Settings.
                """)
        }

        Section {
            Picker("Opens", selection: presetBinding) {
                Text("Claude Code").tag(Preset.claude)
                Text("WTA chat (needs AgentTerm)").tag(Preset.wta)
                Text("Custom command").tag(Preset.custom)
            }
            if customCommand {
                TextField("Command", text: $agentPaneCommand, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...3)
            }
        } header: {
            Text("Agent pane")
        } footer: {
            Text("""
                What starts in the split opened by the ✨ button in the sidebar or by ⌃⌘P. \
                When a command fails, “Fix” in the sidebar opens Claude Code with the error.
                """)
        }
    }

    private func preset(for command: String) -> Preset {
        switch command {
        case AgentSidebarDefaults.defaultAgentPaneCommand: return .claude
        case AgentSidebarDefaults.wtaAgentPaneCommand: return .wta
        default: return .custom
        }
    }

    private var presetBinding: Binding<Preset> {
        Binding(
            get: { customCommand ? .custom : preset(for: agentPaneCommand) },
            set: { preset in
                customCommand = preset == .custom
                switch preset {
                case .claude: agentPaneCommand = AgentSidebarDefaults.defaultAgentPaneCommand
                case .wta: agentPaneCommand = AgentSidebarDefaults.wtaAgentPaneCommand
                case .custom: break
                }
            })
    }

    /// Runs the bundled installer; it keeps existing hooks and makes a backup.
    private func runInstaller(remove: Bool) {
        guard let script = Bundle.main.url(forResource: "install-claude-hooks", withExtension: "py") else {
            hooksMessage = "The installer is missing from the app bundle."
            return
        }
        guard let python = Self.python else {
            hooksMessage = "Python 3 was not found. Install the Xcode Command Line Tools (xcode-select --install) and try again."
            return
        }
        hooksMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script.path] + (remove ? ["--remove"] : [])
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var failure: String?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    failure = output.isEmpty ? "The installer failed." : output
                }
            } catch {
                failure = "Could not run the installer: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                hooksInstalled = Self.detectHooks()
                hooksMessage = failure ?? (remove
                    ? "Turned off."
                    : "Turned on. Restart running Claude Code sessions to see their status.")
            }
        }
    }

    /// A GUI app does not see the shell's PATH.
    private static var python: String? {
        let manager = FileManager.default
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where manager.isExecutableFile(atPath: path) {
            return path
        }
        let tools = ["/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app"]
        if tools.contains(where: { manager.fileExists(atPath: $0) }) {
            return "/usr/bin/python3"
        }
        return nil
    }

    private static func detectHooks() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let script = home.appendingPathComponent(".ghostty-agents/bin/ghostty-agent-hook")
        guard FileManager.default.fileExists(atPath: script.path),
              let settings = try? String(
                  contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
        else { return false }
        return settings.contains("ghostty-agent-hook")
    }
}

// MARK: Advanced

private struct AgentSettingsAdvanced: View {
    @ObservedObject var store: AgentSettingsStore

    var body: some View {
        Section {
            LabeledContent("Ghostty config file") {
                Button("Open in Editor") {
                    (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                }
            }
            LabeledContent("Settings made in this window") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AgentSettingsStore.overridesURL])
                }
                .disabled(store.overrides.isEmpty)
            }
        } header: {
            Text("Files")
        } footer: {
            Text("""
                This window never rewrites the Ghostty config file. Its values are saved to \
                ~/.ghostty-agents/settings.conf and take precedence over the config file. \
                Everything else is still configured in the config file.
                """)
        }

        Section {
            LabeledContent("Changed here") {
                Text(store.overrides.isEmpty ? "Nothing" : store.overrides.keys.sorted().joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button("Reset Settings Made Here", role: .destructive) {
                store.resetAll()
            }
            .disabled(store.overrides.isEmpty)
            Button("Reload Configuration") {
                store.reload()
                (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
            }
        } header: {
            Text("Overrides")
        }
    }
}
