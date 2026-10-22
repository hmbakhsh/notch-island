import AppKit
import SwiftUI

/// The settings window: edits ~/.config/notch-island/config.json and applies
/// each change straight away. Open it with `notch --settings`, Caps Lock then
/// ",", or by opening Island.app again.
final class SettingsWindow {
    private let model: SettingsModel
    private var window: NSWindow?

    init(agenda: Agenda, onChange: @escaping () -> Void) {
        model = SettingsModel(agenda: agenda, onChange: onChange)
    }

    func show() {
        model.config = Config.shared
        model.agenda.reloadIfAllowed()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Island Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.setContentSize(NSSize(width: 460, height: 620))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsModel: ObservableObject {
    @Published var config = Config.shared {
        didSet {
            Config.shared = config
            config.save()
            onChange()
        }
    }
    let agenda: Agenda
    private let onChange: () -> Void

    init(agenda: Agenda, onChange: @escaping () -> Void) {
        self.agenda = agenda
        self.onChange = onChange
    }

    /// A binding to an optional setting, read with its default.
    func binding<T>(_ path: WritableKeyPath<Config, T?>, _ fallback: T) -> Binding<T> {
        Binding(get: { self.config[keyPath: path] ?? fallback }, set: { self.config[keyPath: path] = $0 })
    }

    // MARK: Mirrored apps

    /// Apps worth mirroring that are installed, plus any already in the config.
    var mirrorCandidates: [(name: String, id: String, url: URL?)] {
        let known = [
            ("Slack", "com.tinyspeck.slackmacgap"), ("WhatsApp", "net.whatsapp.WhatsApp"),
            ("Messages", "com.apple.MobileSMS"), ("Granola", "com.granola.app"),
            ("Telegram", "ru.keepcoder.Telegram"), ("Discord", "com.hnc.Discord"),
            ("Linear", "com.linear"), ("Mail", "com.apple.mail"),
            ("Microsoft Teams", "com.microsoft.teams2"), ("Signal", "org.whispersystems.signal-desktop"),
        ]
        let chosen = config.mirrorNotifications ?? []
        let extra = chosen.filter { id in !known.contains { $0.1 == id } }.map { ($0, $0) }
        return (known + extra).compactMap { name, id in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            guard url != nil || chosen.contains(id) else { return nil }
            return (url?.deletingPathExtension().lastPathComponent ?? name, id, url)
        }
    }

    func mirrors(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.config.mirrorNotifications?.contains(id) == true },
            set: { on in
                var ids = self.config.mirrorNotifications ?? []
                ids.removeAll { $0 == id }
                if on { ids.append(id) }
                self.config.mirrorNotifications = ids
            })
    }

    // MARK: Calendars

    /// No list in the config means every calendar shows.
    func shows(_ name: String) -> Binding<Bool> {
        Binding(
            get: { self.config.calendars.map { $0.contains { $0.name == name } } ?? true },
            set: { on in
                var list = self.config.calendars ?? self.agenda.allCalendars.map { CalendarConfig(name: $0.title) }
                list.removeAll { $0.name == name && !on }
                if on, !list.contains(where: { $0.name == name }) { list.append(CalendarConfig(name: name)) }
                self.config.calendars = list
            })
    }

    func label(_ name: String) -> Binding<String> {
        Binding(
            get: { self.config.calendars?.first { $0.name == name }?.label ?? "" },
            set: { text in self.updateCalendar(name) { $0.label = text.isEmpty ? nil : text } })
    }

    func color(_ name: String, fallback: CGColor) -> Binding<Color> {
        Binding(
            get: { self.config.calendars?.first { $0.name == name }?.tint ?? Color(cgColor: fallback) },
            set: { color in self.updateCalendar(name) { $0.color = hex(color) } })
    }

    private func updateCalendar(_ name: String, _ change: (inout CalendarConfig) -> Void) {
        var list = config.calendars ?? agenda.allCalendars.map { CalendarConfig(name: $0.title) }
        if let i = list.firstIndex(where: { $0.name == name }) {
            change(&list[i])
        } else {
            var c = CalendarConfig(name: name)
            change(&c)
            list.append(c)
        }
        config.calendars = list
    }
}

private func hex(_ color: Color) -> String? {
    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    return String(
        format: "#%02X%02X%02X",
        Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
        Int((c.blueComponent * 255).rounded()))
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var agenda: Agenda

    init(model: SettingsModel) {
        self.model = model
        agenda = model.agenda
    }

    var body: some View {
        Form {
            Section {
                Toggle("Caps Lock opens the island", isOn: model.binding(\.capsLockTrigger, false))
                Text("Caps + 1–4 opens a tile, Caps + , opens settings. On a banner, Caps pins it: ⏎ opens it, Esc dismisses it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { FormHeader("Keyboard") }

            Section {
                LabeledContent("Stay on screen") {
                    HStack {
                        Slider(value: model.binding(\.bannerSeconds, 8), in: 3...30, step: 1)
                        Text("\(Int(model.config.banner))s").monospacedDigit().frame(width: 32, alignment: .trailing)
                    }
                }
                Toggle("When T3 agents finish or need you", isOn: model.binding(\.t3Banners, true))
                Toggle("When headphones connect", isOn: model.binding(\.deviceAlerts, true))
            } header: { FormHeader("Banners") }

            Section {
                Toggle("Countdown before meetings", isOn: model.binding(\.meetingReminders, true))
                Picker("Show it", selection: model.binding(\.meetingLeadMinutes, 2)) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) min before").tag($0) }
                }
                .disabled(model.config.meetingReminders == false)
                Picker("Keep it up for", selection: model.binding(\.meetingBannerSeconds, 30)) {
                    ForEach([15.0, 30, 60, 120], id: \.self) { Text("\(Int($0))s").tag($0) }
                }
                .disabled(model.config.meetingReminders == false)
            } header: { FormHeader("Meetings") }

            Section {
                ForEach(model.mirrorCandidates, id: \.id) { app in
                    Toggle(isOn: model.mirrors(app.id)) {
                        HStack(spacing: 8) {
                            if let url = app.url {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 18, height: 18)
                            }
                            Text(app.name)
                        }
                    }
                }
                Picker("List shows up to", selection: model.binding(\.notificationRows, 6)) {
                    ForEach([4, 5, 6, 8, 10], id: \.self) { Text("\($0) rows").tag($0) }
                }
            } header: {
                FormHeader("Notifications to show")
            } footer: {
                HStack {
                    Text("Needs Full Disk Access for Island.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .controlSize(.small)
                }
            }

            Section {
                if agenda.access != .granted {
                    Text("Open the calendar panel once to allow access.").foregroundStyle(.secondary)
                }
                ForEach(agenda.allCalendars, id: \.title) { cal in
                    HStack {
                        Toggle(cal.title, isOn: model.shows(cal.title))
                        Spacer()
                        TextField("Label", text: model.label(cal.title), prompt: Text("Label"))
                            .labelsHidden()
                            .frame(width: 90)
                        ColorPicker("", selection: model.color(cal.title, fallback: cal.color), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            } header: { FormHeader("Calendars") }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 480)
    }
}

/// Grouped-form section header, flush with the card's left edge instead of
/// indented to the row text.
private struct FormHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).padding(.leading, -10) }
}
