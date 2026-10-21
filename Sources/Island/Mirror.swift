import AppKit

/// Mirrors other apps' notifications (e.g. Slack) into the island by reading
/// macOS's notification database, the one Notification Center shows. That
/// file is protected, so Island needs Full Disk Access; without it this logs
/// once and stays quiet. Opt in per app with "mirrorNotifications" in the
/// config, listing bundle ids such as "com.tinyspeck.slackmacgap".
final class NotificationMirror {
    var onMessage: ((Message) -> Void)?
    private let apps: [String]
    private var lastID: Int?
    private var timer: Timer?
    private var warned = false

    private static let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path

    init(apps: [String]) {
        self.apps = apps
    }

    func start() {
        guard !apps.isEmpty else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
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
                log("notification mirror: can't read the notification database; give Island Full Disk Access")
            }
            return
        }
        // First read only finds where "now" is; older notifications aren't replayed.
        defer { lastID = max(lastID ?? 0, result.maxID) }
        guard lastID != nil else { return }
        for row in result.rows {
            if let message = Self.message(app: row.app, data: row.data) { onMessage?(message) }
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
        var m = Message(title: title.isEmpty ? (appURL?.deletingPathExtension().lastPathComponent ?? app) : title)
        m.body = [subtitle, body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        m.source = appURL?.deletingPathExtension().lastPathComponent
        m.image = appURL.map { "app:" + $0.path }
        m.open = appURL?.path
        m.seconds = 5
        m.mirroredFrom = app
        return m
    }

    /// New rows after `after` for the chosen apps, plus the newest id overall.
    /// nil when the database can't be read.
    private static func fetch(after: Int?, apps: [String]) -> (maxID: Int, rows: [(app: String, data: Data)])? {
        let list = apps.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        let query = """
            select r.rec_id, a.identifier, hex(r.data) from record r join app a on a.app_id = r.app_id
            where r.rec_id > \\(after ?? Int.max) and a.identifier in (\\(list)) order by r.rec_id;
            select coalesce(max(rec_id), 0) from record;
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-separator", "\\t", "file:\\(database)?mode=ro", query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        var lines = output.split(separator: "\\n").map(String.init)
        guard let last = lines.popLast(), let maxID = Int(last) else { return nil }
        let rows = lines.compactMap { line -> (app: String, data: Data)? in
            let parts = line.split(separator: "\\t", omittingEmptySubsequences: false)
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
