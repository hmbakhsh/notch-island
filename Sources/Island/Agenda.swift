import AppKit
import EventKit
import SwiftUI

/// Upcoming events from the macOS calendar store (whatever accounts are set up
/// in Calendar.app), for the rest of today and tomorrow.
struct AgendaEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    /// "Work", "Personal": the calendar's label from the config, if it has one.
    let tag: String?
    /// Location, or the meeting service when the location is just a link.
    let detail: String?
    let joinURL: URL?
    /// Calendar.app's link to this event.
    let calendarURL: URL?

    var isNow: Bool { start <= Date() && end > Date() }

    /// What opening the event does: join the call, or show it in Calendar.
    var openURL: URL {
        joinURL ?? calendarURL ?? URL(fileURLWithPath: "/System/Applications/Calendar.app")
    }
}

final class Agenda: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var access = Access.unknown
    private let store = EKEventStore()

    init() {
        access = Self.currentAccess
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) {
            [weak self] _ in self?.reload()
        }
    }

    private static var currentAccess: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    /// Asks for access the first time, then loads. Calls back on main.
    func refresh(_ done: @escaping () -> Void) {
        guard access == .unknown else {
            reload()
            done()
            return
        }
        // Island is a background app; bring it forward so the prompt shows.
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { [weak self] granted, error in
            log("calendar access granted=\(granted) error=\(String(describing: error))")
            DispatchQueue.main.async {
                guard let self else { return }
                self.access = Self.currentAccess
                self.reload()
                done()
            }
        }
    }

    /// Reloads only if access was already granted; never prompts.
    func reloadIfAllowed() {
        access = Self.currentAccess
        reload()
    }

    func reload() {
        guard access == .granted else {
            events = []
            return
        }
        let now = Date()
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))!
        let wanted = Config.shared.calendars?.map(\.name)
        let calendars = store.calendars(for: .event).filter { cal in
            if let wanted { return wanted.contains(cal.title) }
            return cal.type != .birthday && cal.type != .subscription
        }
        guard !calendars.isEmpty else {
            events = []
            return
        }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        events = store.events(matching: predicate)
            .filter { e in
                !e.isAllDay && e.end > now && e.status != .canceled
                    && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
                    && !isOutOfOffice(e.title ?? "")
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(AgendaLayout.maxEvents)
            .map(Self.makeEvent)
    }

    private static let calendarConfigs = Dictionary(
        (Config.shared.calendars ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    private static func makeEvent(_ e: EKEvent) -> AgendaEvent {
        let link = joinLink(in: [e.url?.absoluteString, e.location, e.notes])
        // "Techspace Goswell Road, 140 Goswell Rd, London" → "Techspace Goswell Road"
        var detail = e.location?.components(separatedBy: CharacterSet(charactersIn: ",\n")).first?
            .trimmingCharacters(in: .whitespaces)
        if let d = detail, d.isEmpty || d.hasPrefix("http") { detail = nil }
        if detail == nil, let link { detail = service(of: link) }
        return AgendaEvent(
            id: e.calendarItemIdentifier + "\(e.startDate.timeIntervalSince1970)",
            title: e.title ?? "Untitled",
            start: e.startDate,
            end: e.endDate,
            color: calendarConfigs[e.calendar.title]?.tint ?? Color(cgColor: e.calendar.cgColor),
            tag: calendarConfigs[e.calendar.title]?.label,
            detail: detail,
            joinURL: link,
            calendarURL: e.eventIdentifier
                .flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) }
                .flatMap { URL(string: "ical://ekevent/\($0)?method=show&options=more") })
    }

    private static func joinLink(in fields: [String?]) -> URL? {
        let pattern = #"https://(meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com|teams\.live\.com|[\w.-]*whereby\.com|meet\.around\.co|[\w.-]*webex\.com)/[^\s<>"')]*"#
        for field in fields.compactMap({ $0 }) {
            if let range = field.range(of: pattern, options: .regularExpression) {
                return URL(string: String(field[range]))
            }
        }
        return nil
    }

    private static func service(of url: URL) -> String {
        let host = url.host ?? ""
        if host.contains("meet.google") { return "Google Meet" }
        if host.contains("zoom") { return "Zoom" }
        if host.contains("teams") { return "Teams" }
        if host.contains("whereby") { return "Whereby" }
        if host.contains("webex") { return "Webex" }
        return host
    }

    private func isOutOfOffice(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("out of office") || t.range(of: #"\booo\b"#, options: .regularExpression) != nil
    }
}

private extension EKEvent {
    var end: Date { endDate }
}

/// ~/.config/notch-island/config.json, read once at launch:
///   { "calendars": ["Personal", {"name": "me@work.com", "label": "Work", "color": "#4C8DFF"}],
///     "capsLockTrigger": true }
/// Without "calendars", every calendar except birthdays and subscriptions shows.
/// "capsLockTrigger" makes Caps Lock open and close the island.
struct Config: Decodable {
    var calendars: [CalendarConfig]?
    var capsLockTrigger: Bool?
    /// Banners when T3 threads finish or need you (the live indicator shows
    /// the same thing, so this is off by default).
    var t3Banners: Bool?

    static let shared: Config = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/notch-island/config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }()
}

/// A calendar to show: just its name as in Calendar.app, or the name with a
/// label and colour so events say which calendar they're from.
struct CalendarConfig: Decodable {
    var name: String
    var label: String?
    var color: String?

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    private enum CodingKeys: String, CodingKey { case name, label, color }

    var tint: Color? {
        guard let color else { return nil }
        var m = Message()
        m.color = color
        return m.tint
    }
}

// MARK: - View

enum AgendaLayout {
    static let maxEvents = 6
    static let rowHeight: CGFloat = 50

    static func height(events: [AgendaEvent], access: Agenda.Access) -> CGFloat {
        guard access == .granted, !events.isEmpty else { return 8 + SectionHeader.height + rowHeight + 14 }
        let days = Set(events.map { Calendar.current.startOfDay(for: $0.start) }).count
        return 8 + CGFloat(days) * SectionHeader.height + CGFloat(events.count) * rowHeight + 14
    }
}

struct AgendaView: View {
    @ObservedObject var agenda: Agenda
    /// Highlighted with the arrow keys.
    let selected: String?
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if agenda.access != .granted {
                SectionHeader(text: "Calendar")
                note("Allow calendar access in System Settings", action: {
                    onOpen(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                })
            } else if agenda.events.isEmpty {
                SectionHeader(text: "Today")
                note("Nothing else today or tomorrow", action: nil)
            } else {
                ForEach(days, id: \.self) { day in
                    SectionHeader(text: Calendar.current.isDateInToday(day) ? "Today" : "Tomorrow")
                    ForEach(agenda.events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }) { event in
                        EventRow(event: event, selected: event.id == selected, onOpen: onOpen)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var days: [Date] {
        Array(Set(agenda.events.map { Calendar.current.startOfDay(for: $0.start) })).sorted()
    }

    private func note(_ text: String, action: (() -> Void)?) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(action == nil ? 0.4 : 0.7))
            .padding(.horizontal, 8)
            .frame(height: AgendaLayout.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture { action?() }
    }
}

private struct EventRow: View {
    let event: AgendaEvent
    let selected: Bool
    let onOpen: (URL) -> Void
    @State private var hovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                Capsule().fill(event.color).frame(width: 3.5, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                    Text(event.end.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.35))
                }
                .frame(width: 46, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text([relative(event, at: context.date), event.detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(event.isNow ? Color.green.opacity(0.9) : .white.opacity(0.5))
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                if let tag = event.tag { TagChip(text: tag, color: event.color) }
                if let url = event.joinURL {
                    Button { onOpen(url) } label: {
                        Label("Join", systemImage: "video.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(soon(at: context.date) ? .black : .white)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(soon(at: context.date) ? Color.green : Color.white.opacity(0.14)))
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: AgendaLayout.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.12 : hovered ? 0.08 : event.isNow ? 0.05 : 0)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { onOpen(event.openURL) }
        }
    }

    /// Ongoing or starting within 10 minutes: the Join button turns green.
    private func soon(at now: Date) -> Bool {
        event.start.timeIntervalSince(now) < 600 && event.end > now
    }

    /// Only for today; later days already read clearly from the start time.
    private func relative(_ e: AgendaEvent, at now: Date) -> String? {
        if e.start <= now { return "\(span(e.end.timeIntervalSince(now))) left" }
        guard Calendar.current.isDate(e.start, inSameDayAs: now) else { return nil }
        let until = e.start.timeIntervalSince(now)
        return until < 60 ? "Starting" : "in \(span(until))"
    }

    private func span(_ seconds: TimeInterval) -> String {
        let m = Int((seconds + 59) / 60)
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}

/// A small coloured label saying which calendar an event is from.
struct TagChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.18)))
            .fixedSize()
    }
}

struct SectionHeader: View {
    static let height: CGFloat = 26
    let text: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.white.opacity(0.4))
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.orange))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height, alignment: .center)
    }
}
