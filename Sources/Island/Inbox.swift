import AppKit
import SwiftUI

// MARK: - History

struct Entry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var message: Message
}

/// Every message shown, newest first, kept in ~/.local/state/notch/history.jsonl.
final class History: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var unread = 0
    let directory: URL
    private let url: URL
    private let limit = 200

    init() {
        let dir = ProcessInfo.processInfo.environment["ISLAND_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/notch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        url = dir.appendingPathComponent("history.jsonl")
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n") ?? []
        entries = lines.suffix(limit).reversed().compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    func add(_ message: Message) {
        let entry = Entry(date: Date(), message: message)
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        // Agent updates live in the agents list; they don't count here.
        if !message.fromAgent { unread += 1 }
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    func markRead() { unread = 0 }
}

private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()
private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

// MARK: - T3 threads waiting on the user

struct WaitingThread: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let project: String
    /// running | question | approval | failed | finished
    let reason: String
    let since: String
    /// When the user last had this thread open in T3.
    let visited: String
    let model: String
    let started: String

    var running: Bool { reason == "running" }
    var needsInput: Bool { reason == "question" || reason == "approval" }

    /// Finished since you last opened it.
    var unread: Bool { since > visited }

    /// Unread in T3's sense: asking something, or finished since last opened.
    var waiting: Bool {
        needsInput || ((reason == "finished" || reason == "failed") && since > visited)
    }

    var summary: String {
        switch reason {
        case "question": return "Asked you a question"
        case "approval": return "Waiting for approval"
        case "failed": return "Failed"
        case "running": return "Working"
        default: return "Finished"
        }
    }

    /// "Finished in 1m 6s with Opus 5.5", "Failed after 2m with Sonnet 5.5"
    var status: String {
        var text = summary
        if let d = duration {
            if reason == "finished" { text += " in \(d)" }
            if reason == "failed" { text += " after \(d)" }
        }
        if !needsInput, let m = prettyModel(model) { text += " with \(m)" }
        return text
    }

    private var duration: String? {
        guard !started.isEmpty else { return nil }
        let s = Int(secondsBetween(started, since))
        guard s >= 0 else { return nil }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m"
    }

    var key: String { "\(id)|\(reason)|\(since)" }

    var message: Message {
        var m = Message(title: title)
        m.body = status
        m.source = project.isEmpty || project == "No project" ? nil : project
        m.plain = true
        // Banners show no icon; lists use this one.
        m.icon = reason == "finished" ? "checkmark.circle.fill" : reason == "failed" ? "xmark.octagon.fill" : "questionmark.bubble.fill"
        m.color = reason == "finished" ? "green" : reason == "failed" ? "red" : "orange"
        m.open = T3.threadLink(id)?.absoluteString
        if reason == "question" || reason == "approval" { m.sound = "Glass" }
        return m
    }
}

/// Whichever T3 Code build is installed (stable, Alpha and Nightly share an id).
let t3AppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code")

enum T3 {
    private static let bundleID = "com.t3tools.t3code"

    /// The copy that's running, so links don't launch a different build.
    static var appURL: URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL ?? t3AppURL
    }

    /// t3code://threads/<environment>/<thread>, T3's own link to a thread.
    static func threadLink(_ threadID: String) -> URL? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata/environment-id")
        guard let environment = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !environment.isEmpty
        else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let env = environment.addingPercentEncoding(withAllowedCharacters: allowed),
              let thread = threadID.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "t3code://threads/\(env)/\(thread)")
    }

    /// Opens a thread in T3, or just brings T3 forward if there's no link.
    static func open(thread threadID: String?) {
        guard let app = appURL else { return }
        if let threadID, let link = threadLink(threadID) {
            open(link: link)
        } else {
            NSWorkspace.shared.open(app)
        }
    }

    static func open(link: URL) {
        guard let app = appURL else { return }
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Polls T3's local state database. T3 has no public hook for thread status,
/// so this reads its internal tables read-only; if a T3 update changes the
/// schema the query fails and the watcher just reports nothing.
final class T3Watcher: ObservableObject {
    /// Needs you: a question, an approval, or finished/failed since you looked.
    @Published private(set) var waiting: [WaitingThread] = []
    /// Working right now.
    @Published private(set) var running: [WaitingThread] = []
    /// Finished or failed in the last 12 hours, read or not, newest first.
    @Published private(set) var completed: [WaitingThread] = []
    /// Banners for threads that finish or need you; off by default since the
    /// live indicator and agents panel show the same thing.
    var announces = false
    var onNew: ((WaitingThread) -> Void)?
    var onChange: (() -> Void)?
    private var seen: Set<String>?
    private var timer: Timer?

    private static let database = ProcessInfo.processInfo.environment["ISLAND_T3_DB"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata/statev2.sqlite").path

    private static let query = """
        with latest as (
          select thread_id, status, completed_at, payload_json,
                 row_number() over (partition by thread_id order by ordinal desc) rn
          from orchestration_v2_projection_runs),
        -- Subagent threads, per top-level thread: is any still working, and
        -- when did the last one finish. A parent whose own turn has ended is
        -- still working while its subagents are.
        kids as (
          select json_extract(c.payload_json, '$.lineage.rootThreadId') root,
                 max(k.status in ('waiting', 'queued', 'preparing', 'starting', 'running')) busy,
                 max(k.completed_at) done
          from orchestration_v2_projection_threads c
          join latest k on k.thread_id = c.thread_id and k.rn = 1
          where json_extract(c.payload_json, '$.lineage.parentThreadId') is not null
          group by root),
        pending as (
          select thread_id, min(created_at) since
          from orchestration_v2_projection_runtime_requests where status = 'pending' group by thread_id)
        select t.thread_id id, t.title, coalesce(p.title, '') project,
          -- A run also sits in 'waiting' while its subagents work; that's
          -- working, not waiting for you.
          case when q.thread_id is not null then 'question'
               when l.status in ('queued', 'preparing', 'starting', 'running') or k.busy then 'running'
               when l.status = 'waiting' then 'approval'
               when l.status = 'failed' then 'failed'
               else 'finished' end reason,
          coalesce(q.since,
                   case when k.busy then json_extract(l.payload_json, '$.startedAt')
                        else max(l.completed_at, coalesce(k.done, '')) end,
                   l.completed_at, json_extract(l.payload_json, '$.startedAt'), t.updated_at) since,
          coalesce(json_extract(t.payload_json, '$.lastVisitedAt'), '') visited,
          coalesce(json_extract(l.payload_json, '$.modelSelection.model'), '') model,
          coalesce(json_extract(l.payload_json, '$.startedAt'), '') started
        from orchestration_v2_projection_threads t
        join latest l on l.thread_id = t.thread_id and l.rn = 1
        left join pending q on q.thread_id = t.thread_id
        left join kids k on k.root = t.thread_id
        left join projection_projects p on p.project_id = t.project_id
        where t.archived_at is null and t.deleted_at is null
          and json_extract(t.payload_json, '$.settledAt') is null
          and json_extract(t.payload_json, '$.lineage.parentThreadId') is null
          and coalesce(json_extract(t.payload_json, '$.snoozedUntil'), '') < strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
          and (q.thread_id is not null or k.busy or l.status in ('waiting', 'queued', 'preparing', 'starting', 'running')
               or (l.status in ('completed', 'failed')
                   and (l.completed_at > coalesce(json_extract(t.payload_json, '$.lastVisitedAt'), '')
                        or l.completed_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-12 hours'))))
        order by since desc;
        """

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async {
            let threads = Self.fetch()
            DispatchQueue.main.async { self.update(threads) }
        }
    }

    private func update(_ rows: [WaitingThread]?) {
        guard let rows else { return }
        let now = isoNow()
        if seen == nil {
            // First poll after launch: remember what's there, announce nothing.
            // ISLAND_ANNOUNCE_EXISTING=1 announces it all instead, for testing.
            seen = ProcessInfo.processInfo.environment["ISLAND_ANNOUNCE_EXISTING"] == "1"
                ? [] : Set(rows.map(\.key))
        }
        // Oldest first so the queue reads in order.
        for row in rows.reversed() where !seen!.contains(row.key) {
            // T3 marks the selected thread visited a few seconds after it
            // settles; wait for that before deciding whether you saw it.
            guard secondsBetween(row.since, now) >= 5 else { continue }
            seen!.insert(row.key)
            guard announces, !row.running else { continue }
            if !(t3IsFrontmost && row.visited >= row.since) { onNew?(row) }
        }
        let needs = rows.filter(\.waiting)
        let working = rows.filter(\.running)
        let done = rows.filter { $0.reason == "finished" || $0.reason == "failed" }
        if needs != waiting || working != running || done != completed {
            waiting = needs
            running = working
            completed = done
            onChange?()
        }
    }

    private var t3IsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.t3tools.t3code"
    }

    private static func fetch() -> [WaitingThread]? {
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", "file:\(database)?mode=ro", query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        if data.isEmpty { return [] }  // sqlite3 prints nothing for zero rows
        return try? JSONDecoder().decode([WaitingThread].self, from: data)
    }
}

// MARK: - Notifications panel

/// One row in the notifications panel: a single message, or for mirrored
/// apps (Slack) the latest message in a channel with how many came in.
struct NotificationGroup: Identifiable {
    let latest: Entry
    let count: Int
    var id: String { latest.id.uuidString }
}

extension Message {
    /// A banner about a T3 thread (finished, failed, needs you).
    var fromAgent: Bool { open?.hasPrefix("t3code:") == true || source == "T3" }  // "T3": older entries
}

enum InboxLayout {
    static let rowHeight: CGFloat = 44
    static let maxPerApp = 4
    static let maxOther = 3
    /// Rows in the notifications list overall (default 6; set in settings).
    static var maxRows: Int { Config.shared.notificationRows ?? 6 }
}

/// Notifications, grouped: a section per mirrored app (Slack) with a row per
/// channel from the last day, then everything else.
struct InboxView: View {
    @ObservedObject var history: History
    /// Highlighted with the arrow keys.
    let selected: String?
    let onOpenEntry: (Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let sections = Self.sections(history)
            if sections.isEmpty {
                SectionHeader(text: "Notifications")
                Text("Nothing yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .frame(height: InboxLayout.rowHeight)
            }
            ForEach(sections, id: \.title) { section in
                SectionHeader(text: section.title)
                ForEach(section.groups) { group in
                    let message = group.latest.message.listed
                    Row(
                        leading: AnyView(MessageIcon(message: message, size: 28)),
                        title: message.title,
                        detail: message.mirroredFrom == nil
                            ? [message.source, message.body].compactMap { $0 }.joined(separator: " · ")
                            : message.body ?? "",
                        time: relative(group.latest.date),
                        badge: group.count > 1 ? group.count : nil,
                        selected: group.id == selected,
                        action: { onOpenEntry(group.latest) })
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    static func sections(_ history: History) -> [(title: String, groups: [NotificationGroup])] {
        let dayAgo = Date().addingTimeInterval(-86400)
        var mirrored: [String: [String: [Entry]]] = [:]  // app → channel → entries, newest first
        var appOrder: [String] = []
        var other: [Entry] = []
        for entry in history.entries {
            let m = entry.message
            if m.fromAgent { continue }  // the agents list shows these
            guard m.mirroredFrom != nil else {
                if other.count < InboxLayout.maxOther { other.append(entry) }
                continue
            }
            guard entry.date > dayAgo else { continue }
            let app = m.source?.components(separatedBy: " · ").first ?? "Apps"
            let channel = (m.source ?? "") + "|" + m.title
            if mirrored[app] == nil { appOrder.append(app) }
            mirrored[app, default: [:]][channel, default: []].append(entry)
        }

        var out: [(String, [NotificationGroup])] = []
        var left = InboxLayout.maxRows
        for app in appOrder where left > 0 {
            let groups = (mirrored[app] ?? [:]).values
                .map { NotificationGroup(latest: $0[0], count: $0.count) }
                .sorted { $0.latest.date > $1.latest.date }
                .prefix(min(InboxLayout.maxPerApp, left))
            out.append((app, Array(groups)))
            left -= groups.count
        }
        if !other.isEmpty, left > 0 {
            let groups = other.prefix(left).map { NotificationGroup(latest: $0, count: 1) }
            out.append((appOrder.isEmpty ? "Recent" : "Other", groups))
        }
        return out.map { (title: $0.0, groups: $0.1) }
    }

    /// Rows top to bottom, as the arrow keys walk them.
    static func order(_ history: History) -> [String] {
        sections(history).flatMap { $0.groups.map(\.id) }
    }

    static func entry(_ id: String, in history: History) -> Entry? {
        history.entries.first { $0.id.uuidString == id }
    }

    static func height(_ history: History) -> CGFloat {
        let sections = sections(history)
        guard !sections.isEmpty else { return 8 + SectionHeader.height + InboxLayout.rowHeight + 14 }
        let rows = sections.reduce(0) { $0 + $1.groups.count }
        return 8 + CGFloat(sections.count) * SectionHeader.height + CGFloat(rows) * InboxLayout.rowHeight + 14
    }
}

private struct Row: View {
    let leading: AnyView
    let title: String
    let detail: String
    let time: String
    var badge: Int? = nil
    var selected = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let badge {
                Text("\(badge)")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(Color.white.opacity(0.8)))
            }
            Text(time)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .frame(height: InboxLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.12 : hovered ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}

/// claude-opus-5-5 → Opus 5.5, gpt-6.1-sol → GPT-6.1 Sol
func prettyModel(_ id: String) -> String? {
    guard !id.isEmpty else { return nil }
    var parts = id.split(separator: "-").map(String.init)
    if parts.first == "claude" {
        parts.removeFirst()
        let name = parts.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? name : "\(name) \(version)"
    }
    if parts.first == "gpt", parts.count > 1 {
        let rest = parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (["GPT-\(parts[1])"] + rest).joined(separator: " ")
    }
    return id
}

private func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

private func secondsBetween(_ a: String, _ b: String) -> Double {
    isoDate(b).timeIntervalSince(isoDate(a))
}

func isoDate(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date()
}

private func relative(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    let f = DateFormatter()
    f.dateFormat = s < 7 * 86400 ? "EEE" : "d MMM"
    return f.string(from: date)
}
