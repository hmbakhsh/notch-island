import AppKit

/// Mirrors other apps' notifications (e.g. Slack) into the island by reading
/// macOS's notification database, the one Notification Center shows. That
/// file is protected, so Island needs Full Disk Access; without it this logs
/// once and stays quiet. Opt in per app with "mirrorNotifications" in the
/// config, listing bundle ids such as "com.tinyspeck.slackmacgap".
final class NotificationMirror {
    var onMessage: ((Message) -> Void)?
    private(set) var apps: [String]
    private var lastID: Int?
    private var timer: Timer?
    private var warned = false

    private static var lastError = ""
    private static let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path

    init(apps: [String]) {
        self.apps = apps
    }

    /// Switches to another set of apps, from the settings window.
    func setApps(_ apps: [String]) {
        guard apps != self.apps else { return }
        timer?.invalidate()
        timer = nil
        self.apps = apps
        lastID = nil
        start()
    }

    func start() {
        guard !apps.isEmpty else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Shows the most recent mirrored notification again, for testing.
    func replayLatest() {
        let after = (lastID ?? 0) - 500
        DispatchQueue.global(qos: .utility).async {
            if let last = Self.fetch(after: after, apps: self.apps)?.rows.last { Self.describe(last.data) }
            guard let last = Self.fetch(after: after, apps: self.apps)?.rows.last,
                  let message = Self.message(app: last.app, data: last.data)
            else {
                log("notification mirror: nothing to replay")
                return
            }
            DispatchQueue.main.async { self.onMessage?(message) }
        }
    }

    private func poll() {
        let after = lastID
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetch(after: after, apps: self.apps)
            DispatchQueue.main.async { self.handle(result) }
        }
    }

    private func handle(_ result: (maxID: Int, rows: [(app: String, data: Data)])?) {
        guard let result else {
            if !warned {
                warned = true
                log("notification mirror: can't read the notification database (\(Self.lastError)); give Island Full Disk Access")
            }
            return
        }
        // First read only finds where "now" is; older notifications aren't replayed.
        defer { lastID = max(lastID ?? 0, result.maxID) }
        guard lastID != nil else {
            log("notification mirror: reading notifications from \(apps.joined(separator: ", "))")
            return
        }
        for row in result.rows {
            if let message = Self.message(app: row.app, data: row.data) { onMessage?(message) }
        }
    }

    /// Logs the shape of a stored notification (keys, and the values of any
    /// id-like fields), to see what an app includes for deep links.
    private static func describe(_ data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        log("notification keys: \(plist.keys.sorted())")
        if let request = plist["req"] as? [String: Any] {
            log("request keys: \(request.keys.sorted())")
            for (key, value) in request where !["titl", "subt", "body"].contains(key) {
                var shown = "\(value)"
                if let data = value as? Data,
                   let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                    shown = "plist \(inner)"
                }
                log("  \(key) = \(shown.prefix(400))")
            }
        }
    }

    /// The notification's title, subtitle and body from its stored property list.
    private static func message(app: String, data: Data) -> Message? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any]
        else { return nil }
        let title = (request["titl"] as? String) ?? ""
        let subtitle = request["subt"] as? String
        let body = request["body"] as? String
        guard !title.isEmpty || body?.isEmpty == false else { return nil }

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
        let appName = appURL?.deletingPathExtension().lastPathComponent ?? app
        var m = Message(title: title.isEmpty ? appName : title)
        m.body = body
        m.source = appName
        // Slack and similar put the workspace in the title and the channel in
        // the subtitle: lead with the channel, keep the workspace as the label.
        if let subtitle, !subtitle.isEmpty {
            m.title = subtitle
            m.source = title.isEmpty ? appName : "\(appName) · \(title)"
        }
        m.image = appURL.map { "app:" + $0.path }
        m.open = appURL?.path
        // Slack's notification id starts with the workspace ("T0B2…_<ts>"); the
        // channel id isn't stored, so open Slack on the right workspace.
        if app == "com.tinyspeck.slackmacgap", let id = request["iden"] as? String,
           id.hasPrefix("T"), let team = id.split(separator: "_").first {
            m.open = "slack://open?team=\(team)"
            m.slackID = id
        }
        m.mirroredFrom = app
        return m
    }

    /// New rows after `after` for the chosen apps, plus the newest id overall.
    /// nil when the database can't be read.
    private static func fetch(after: Int?, apps: [String]) -> (maxID: Int, rows: [(app: String, data: Data)])? {
        let list = apps.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        let query = """
            select r.rec_id, a.identifier, hex(r.data) from record r join app a on a.app_id = r.app_id
            where r.rec_id > \(after ?? Int.max) and a.identifier in (\(list)) order by r.rec_id;
            select coalesce(max(rec_id), 0) from record;
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-separator", "\t", "file:\(database)?mode=ro", query]
        let pipe = Pipe()
        process.standardOutput = pipe
        let errors = Pipe()
        process.standardError = errors
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            lastError = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        }

        var lines = output.split(separator: "\n").map(String.init)
        guard let last = lines.popLast(), let maxID = Int(last) else { return nil }
        let rows = lines.compactMap { line -> (app: String, data: Data)? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, let data = Data(hex: String(parts[2])) else { return nil }
            return (String(parts[1]), data)
        }
        return (maxID, rows)
    }
}

private extension Data {
    init?(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

/// Finds the message a Slack notification came from. macOS doesn't store
/// where it was, but Slack's own log does: each notification is logged as a
/// NEW_NOTIFICATION block with the same id ("T<team>_<ts>"), the channel
/// ("C…", or "D…" for DMs) and, for replies, the thread. The link is the one
/// Slack builds for its own notifications, so it opens the thread. The logs rotate at about 5 MB, so this works for
/// roughly a day; after that the caller falls back to opening the workspace.
enum Slack {
    private static let logs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Slack/logs/Default")
    private static let channel = try! NSRegularExpression(pattern: #""channel": "([CDG][A-Z0-9]+)""#)
    private static let message = try! NSRegularExpression(pattern: #""msg": "(\d+\.\d+)""#)
    private static let thread = try! NSRegularExpression(pattern: #""thread_ts": "(\d+\.\d+)""#)

    static func channelLink(notification id: String) -> URL? {
        guard let team = id.split(separator: "_").first, team.hasPrefix("T") else { return nil }
        for file in ["webapp-console.log", "webapp-console1.log", "webapp-console2.log", "browser.log"] {
            guard let text = try? String(contentsOf: logs.appendingPathComponent(file), encoding: .utf8),
                  let hit = text.range(of: "\"id\": \"\(id)\"", options: .backwards),
                  let start = text.range(of: "NEW_NOTIFICATION", options: .backwards, range: text.startIndex..<hit.lowerBound)
            else { continue }
            // The block runs until the next log line, which starts with "\n[".
            let end = text.range(of: "\n[", range: hit.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
            let block = String(text[start.lowerBound..<end])
            guard let channel = first(channel, in: block) else { continue }
            let ts = first(message, in: block) ?? String(id.split(separator: "_").last ?? "")
            var link = "slack://channel?id=\(channel)&message=\(ts)&team=\(team)"
            // A reply opens its thread; a post in a channel opens as a thread
            // too, so its replies show. DMs just jump to the message.
            if let thread = first(thread, in: block) ?? (channel.hasPrefix("D") ? nil : ts) {
                link += "&thread_ts=\(thread)"
            }
            return URL(string: link)
        }
        log("slack: no channel found in Slack's logs for \(id)")
        return nil
    }

    /// The id of the Slack notification logged just before `date`, for
    /// entries saved before ids were kept. Slack logs a notification about
    /// 5–10s before macOS stores it and Island picks it up.
    static func notificationID(near date: Date, team: String?) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy, HH:mm:ss:SSS"
        var best: (id: String, gap: TimeInterval)?
        for file in ["webapp-console.log", "webapp-console1.log", "webapp-console2.log"] {
            guard let text = try? String(contentsOf: logs.appendingPathComponent(file), encoding: .utf8) else { continue }
            for match in logged.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let stamp = Range(match.range(at: 1), in: text).flatMap({ formatter.date(from: String(text[$0])) }),
                      let id = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                      team.map({ id.hasPrefix($0) }) ?? true
                else { continue }
                let gap = date.timeIntervalSince(stamp)
                guard gap > -1, gap < 20, gap < best?.gap ?? .infinity else { continue }
                best = (id, gap)
            }
        }
        return best?.id
    }

    /// "[10/22/26, 08:25:46:123] info: Store: NEW_NOTIFICATION { … "id": "T…_…""
    private static let logged = try! NSRegularExpression(
        pattern: #"\[(\d\d/\d\d/\d\d, [\d:]+)\] info: Store: NEW_NOTIFICATION \{(?:(?!\n\[)[\s\S])*?"id": "(T[A-Z0-9]+_\d+\.\d+)""#)

    private static func first(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

extension Entry {
    /// Opens the entry; a Slack one saved without its id is matched to Slack's
    /// log by when it arrived, so it still opens its channel or thread.
    func open() {
        var m = message
        if m.slackID == nil, m.mirroredFrom == "com.tinyspeck.slackmacgap" {
            let team = m.open.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "team" }?.value }
            m.slackID = Slack.notificationID(near: date, team: team)
        }
        m.perform()
    }
}
