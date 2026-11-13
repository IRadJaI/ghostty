import SwiftUI

/// What agents did while the user was looking elsewhere, newest first.
@MainActor
final class AgentFeed: ObservableObject {
    static let shared = AgentFeed()

    private static let limit = 50
    private static let key = "AgentSidebarFeed"

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let tabID: String
        let session: String?
        let label: String
        let title: String
        let state: String
        let text: String
        let date: Date
        var read = false
    }

    @Published private(set) var entries: [Entry] = []
    /// Bumped to open the list from outside the view.
    @Published var presentRequest = 0

    var unreadCount: Int { entries.lazy.filter { !$0.read }.count }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// `events` are the tabs whose agent just started waiting, failed or finished
    /// out of sight; `front` are the tabs the user is looking at.
    func update(_ tabs: [AgentSidebarModel.Tab], events: Set<String>, front: Set<String>) {
        var next = entries
        for index in next.indices where !next[index].read && front.contains(next[index].tabID) {
            next[index].read = true
        }
        for tab in tabs where events.contains(tab.stableID) {
            guard let state = tab.state else { continue }
            // Only the latest unseen event of a tab is worth keeping.
            next.removeAll { $0.tabID == tab.stableID && !$0.read }
            next.insert(Entry(
                tabID: tab.stableID,
                session: tab.sessionID,
                label: AgentSidebarMonogram(tab: tab).letters,
                title: tab.title,
                state: state.rawValue,
                text: Self.text(tab, state),
                date: Date()
            ), at: 0)
        }
        if next.count > Self.limit {
            next.removeLast(next.count - Self.limit)
        }
        commit(next)
    }

    func markAllRead() {
        var next = entries
        for index in next.indices {
            next[index].read = true
        }
        commit(next)
    }

    func clear() {
        commit([])
    }

    func tab(for entry: Entry) -> AgentSidebarModel.Tab? {
        let tabs = AgentSidebarModel.shared.tabs
        return tabs.first { $0.stableID == entry.tabID }
            ?? entry.session.flatMap { session in tabs.first { $0.sessionID == session } }
    }

    private func commit(_ next: [Entry]) {
        guard next != entries else { return }
        entries = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static func text(_ tab: AgentSidebarModel.Tab, _ state: AgentState) -> String {
        let message = tab.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch state {
        case .waiting: return message.isEmpty ? "Needs you" : message
        case .error: return message.isEmpty ? "Stopped with an error" : message
        default: return "Finished"
        }
    }
}

/// The bell that opens the list.
struct AgentFeedButton: View {
    /// Width of the icon column; nil in the header of the open sidebar.
    var railWidth: CGFloat?
    var showLabel = false

    @ObservedObject private var feed = AgentFeed.shared
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell")
                    .overlay(alignment: .topTrailing) { badge }
                    .frame(width: railWidth, height: railWidth == nil ? nil : 24)
                    .padding(.trailing, railWidth == nil && feed.unreadCount > 0 ? 5 : 0)
                if showLabel {
                    Text("Notifications")
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .agentTooltip("Notifications")
        .accessibilityLabel("Notifications")
        .accessibilityValue(feed.unreadCount > 0 ? "\(feed.unreadCount) unread" : "")
        .popover(isPresented: $presented, arrowEdge: railWidth == nil ? .bottom : .trailing) {
            AgentFeedList { presented = false }
        }
        .onChange(of: feed.presentRequest) { _ in presented = true }
    }

    @ViewBuilder
    private var badge: some View {
        let count = feed.unreadCount
        if count > 0 {
            Text(count > 9 ? "9+" : "\(count)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 12, minHeight: 12)
                .background(Capsule().fill(Color.red))
                .offset(x: 7, y: -5)
                .fixedSize()
        }
    }
}

private struct AgentFeedList: View {
    let close: () -> Void

    @ObservedObject private var feed = AgentFeed.shared
    @ObservedObject private var model = AgentSidebarModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()
                Button("Clear") { feed.clear() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(feed.entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            if feed.entries.isEmpty {
                Text("Nothing happened while you were away")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 22)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(feed.entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 340)
        .onDisappear { feed.markAllRead() }
    }

    private func row(_ entry: AgentFeed.Entry) -> some View {
        let tab = feed.tab(for: entry)
        let state = AgentState(rawValue: entry.state) ?? .done
        return Button {
            guard let tab else { return }
            close()
            model.select(tab)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(AgentSidebarStyle.color(for: state))
                    .frame(width: 7, height: 7)
                Text(entry.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .frame(width: 36, alignment: .leading)
                Text(entry.text)
                    .font(.callout)
                    .fontWeight(entry.read ? .regular : .medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Self.age(entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .opacity(tab == nil ? 0.45 : (entry.read ? 0.6 : 1))
        }
        .buttonStyle(.plain)
        .help(tab == nil ? "\(entry.title) — tab is closed" : entry.title)
    }

    private static func age(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
