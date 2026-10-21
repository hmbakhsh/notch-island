import AppKit
import SwiftUI

/// What hovering the notch shows: one tile each for the next event, the inbox
/// and Spotify. Clicking a tile grows the island into that panel.
enum HomeLayout {
    static let height: CGFloat = 122
}

struct HomeView: View {
    @ObservedObject var agenda: Agenda
    @ObservedObject var player: Player
    @ObservedObject var watcher: T3Watcher
    @ObservedObject var history: History
    /// Show 1/2/3 keycaps on the tiles.
    let keyboard: Bool
    let open: (Island.Panel) -> Void
    let join: (URL) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Tile(icon: "calendar", label: nextEvent?.isNow == true ? "Now" : "Next", key: keyboard ? 1 : nil) { open(.calendar) } content: {
                calendar
            }
            Tile(icon: "sparkles", label: "Agents", key: keyboard ? 2 : nil) { open(.agents) } content: {
                agents
            }
            Tile(icon: "music.note", label: "Spotify", key: keyboard ? 3 : nil) { open(.player) } content: {
                spotify
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var nextEvent: AgendaEvent? { agenda.events.first }

    @ViewBuilder private var calendar: some View {
        if agenda.access != .granted {
            primary("Set up calendar")
        } else if let event = nextEvent {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    primary(event.title)
                    HStack(spacing: 5) {
                        if let tag = event.tag { TagChip(text: tag, color: event.color) }
                        secondary(when(event), color: event.isNow ? .green : nil)
                    }
                }
                if let url = event.joinURL {
                    Spacer(minLength: 2)
                    CircleButton(symbol: "video.fill", tint: .green) { join(url) }
                }
            }
        } else {
            primary("No more events")
        }
    }

    @ViewBuilder private var agents: some View {
        let needs = watcher.waiting.filter { $0.needsInput || $0.reason == "failed" }.count
        if watcher.running.isEmpty && watcher.waiting.isEmpty {
            primary("No agents running")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if !watcher.running.isEmpty {
                    HStack(spacing: 6) {
                        Spinner(size: 12)
                        primary("\(watcher.running.count) working", lines: 1)
                    }
                }
                if needs > 0 {
                    secondary("\(needs) need\(needs == 1 ? "s" : "") you", color: .orange)
                } else if !watcher.waiting.isEmpty {
                    secondary("\(watcher.waiting.count) done", color: .green)
                }
            }
        }
    }

    @ViewBuilder private var spotify: some View {
        if player.running, !player.title.isEmpty {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    primary(player.title)
                    secondary(player.artist)
                }
                Spacer(minLength: 2)
                CircleButton(symbol: player.playing ? "pause.fill" : "play.fill", tint: .white) {
                    player.send("playpause")
                }
            }
        } else {
            primary("Not playing")
        }
    }

    private func primary(_ text: String, lines: Int = 2) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func secondary(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color ?? .white.opacity(0.5))
            .lineLimit(1)
    }

    private func when(_ e: AgendaEvent) -> String {
        let now = Date()
        if e.start <= now { return "\(span(e.end.timeIntervalSince(now))) left" }
        if !Calendar.current.isDate(e.start, inSameDayAs: now) {
            return "Tomorrow " + e.start.formatted(date: .omitted, time: .shortened)
        }
        return "in \(span(e.start.timeIntervalSince(now)))"
    }

    private func span(_ seconds: TimeInterval) -> String {
        let m = Int((seconds + 59) / 60)
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}

private struct Tile<Content: View>: View {
    let icon: String
    let label: String
    let key: Int?
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).kerning(0.5)
                Spacer(minLength: 0)
                if let key {
                    Text("\(key)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 17, height: 17)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.12)))
                }
            }
            .foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 6)
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.12 : 0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

private struct CircleButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint))
        }
        .buttonStyle(PressStyle())
    }
}
