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

/// Finds which channel a Slack notification came from. macOS doesn't store
/// it, but Slack's own log does: each notification is logged as a
/// NEW_NOTIFICATION block with the same id ("T<team>_<ts>") and the channel
/// ("C…", or "D…" for DMs). The logs rotate at about 5 MB, so this works for
/// roughly a day; after that the caller falls back to opening the workspace.
enum Slack {
    private static let logs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Slack/logs/Default")
    private static let channel = try! NSRegularExpression(pattern: #""channel": "([CDG][A-Z0-9]+)""#)

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
            guard let match = channel.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
                  let range = Range(match.range(at: 1), in: block)
            else { continue }
            return URL(string: "slack://channel?team=\(team)&id=\(block[range])")
        }
        log("slack: no channel found in Slack's logs for \(id)")
        return nil
    }
}
