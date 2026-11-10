import AppKit
import UserNotifications

// Fork addition (agent-sidebar): tells when upstream Ghostty has a newer release than the fork's base.

@MainActor
final class AgentUpstreamCheck: ObservableObject {
    static let shared = AgentUpstreamCheck()

    static let notificationKey = "agentSidebarUpstream"
    private static let feed = URL(string: "https://release.files.ghostty.org/appcast.xml")!

    /// The upstream version this build is based on, e.g. `1.4.0`.
    let base: String = AgentUpstreamCheck.version(in: Ghostty.info.version) ?? Ghostty.info.version

    @Published private(set) var latest: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checking = false
    @Published private(set) var failure: String?

    private var timer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        latest = defaults.string(forKey: AgentSidebarDefaults.upstreamLatest)
        let checked = defaults.double(forKey: AgentSidebarDefaults.upstreamLastCheck)
        lastChecked = checked > 0 ? Date(timeIntervalSince1970: checked) : nil
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.isNewer(latest, than: base)
    }

    var releaseNotes: URL? {
        guard let latest else { return nil }
        return URL(string: "https://ghostty.org/docs/install/release-notes/"
            + latest.replacingOccurrences(of: ".", with: "-"))
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in AgentUpstreamCheck.shared.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            Task { @MainActor in self.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let interval: TimeInterval
        switch UserDefaults.standard.string(forKey: AgentSidebarDefaults.upstreamInterval) ?? "weekly" {
        case "daily": interval = 86400
        case "monthly": interval = 30 * 86400
        case "never": return
        default: interval = 7 * 86400
        }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < interval { return }
        check()
    }

    func check() {
        guard !checking else { return }
        checking = true
        failure = nil
        var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("ghostty-agent-sidebar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                self.finish(text: status == 200 ? text : nil, error: error?.localizedDescription
                    ?? (status.map { "The server answered \($0)." } ?? "No answer."))
            }
        }.resume()
    }

    private func finish(text: String?, error: String) {
        checking = false
        guard let text, let newest = Self.newestVersion(inFeed: text) else {
            failure = text == nil ? error : "The release list has no versions."
            return
        }
        let defaults = UserDefaults.standard
        latest = newest
        lastChecked = Date()
        defaults.set(newest, forKey: AgentSidebarDefaults.upstreamLatest)
        defaults.set(Date().timeIntervalSince1970, forKey: AgentSidebarDefaults.upstreamLastCheck)

        guard updateAvailable, defaults.string(forKey: AgentSidebarDefaults.upstreamNotified) != newest else { return }
        defaults.set(newest, forKey: AgentSidebarDefaults.upstreamNotified)
        let content = UNMutableNotificationContent()
        content.title = "Ghostty \(newest) is out"
        content.body = "This build is based on Ghostty \(base). Rebuild the fork on the new version to update."
        content.userInfo = [Self.notificationKey: newest]
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            center.add(UNNotificationRequest(identifier: "agent-sidebar-upstream", content: content, trigger: nil))
        }
    }

    // MARK: Versions

    nonisolated static func version(in text: String) -> String? {
        text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(text[$0]) }
    }

    nonisolated static func newestVersion(inFeed feed: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: #"shortVersionString>\s*(\d+\.\d+\.\d+)\s*<"#) else {
            return nil
        }
        let range = NSRange(feed.startIndex..., in: feed)
        let versions = pattern.matches(in: feed, range: range).compactMap { match in
            Range(match.range(at: 1), in: feed).map { String(feed[$0]) }
        }
        return versions.max { isNewer($1, than: $0) }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
