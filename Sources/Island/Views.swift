import AppKit
import SwiftUI

enum Content {
    case player
    case message(Message)
    case inbox(height: CGFloat)
    case calendar(height: CGFloat)
    case agents(height: CGFloat)
    case home

    /// Identity for cross-fading between kinds of content.
    var key: String {
        switch self {
        case .player: return "player"
        case .message(let m): return "message:" + m.title + (m.body ?? "")
        case .inbox: return "inbox"
        case .calendar: return "calendar"
        case .agents: return "agents"
        case .home: return "home"
        }
    }

    var height: CGFloat {
        switch self {
        case .player: return 168
        case .message(let m): return m.body == nil ? 60 : 82
        case .inbox(let height), .calendar(let height), .agents(let height): return height
        case .home: return HomeLayout.height
        }
    }
}

final class IslandState: ObservableObject {
    /// Drives the container. Content follows separately, after the container
    /// has mostly grown, so nothing pops in over a half-drawn shape.
    @Published var open = false
    @Published var showContent = false
    @Published var content = Content.player
    /// Opened from the keyboard: number keys act on the overview's tiles.
    @Published var keyboard = false
    /// The thread highlighted with the arrow keys in the agents list.
    @Published var selectedThread: String?
    /// Agents working or waiting: shown as wings beside the notch while closed.
    @Published var live: LiveCounts?

    var liveHeight: CGFloat { max(notch.height, LiveLayout.minHeight) }
    var liveWidth: CGFloat { notch.width + LiveLayout.wing * 2 }
    /// The notch (or, on screens without one, a sliver at the top centre).
    @Published var notch = CGSize(width: 200, height: 0)
}

let islandWidth: CGFloat = 380
let shadowRoom: CGFloat = 24

struct IslandView: View {
    @ObservedObject var state: IslandState
    let player: Player
    let history: History
    let watcher: T3Watcher
    let agenda: Agenda
    let onMessageTap: () -> Void
    let onMessageHover: (Bool) -> Void
    let onOpenThread: (String) -> Void
    let onOpenEntry: (Entry) -> Void
    let onOpenURL: (URL) -> Void
    let onOpenPanel: (Island.Panel) -> Void
    let onOpenAgent: (String) -> Void

    var body: some View {
        let radius: CGFloat = state.open ? 30 : 10
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
        let compact = !state.open && state.live != nil
        let width = state.open ? islandWidth : compact ? state.liveWidth : state.notch.width
        let height = state.open ? state.notch.height + state.content.height
            : compact ? state.liveHeight : state.notch.height
        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(state.open ? 0.45 : 0), radius: 14, y: 6)
            // Content is clipped to the shape, so the island reveals it as it
            // grows and old/new content cross-fade inside it when it changes.
            ZStack(alignment: .top) {
                content
                    .frame(width: islandWidth, height: state.content.height)
                    .padding(.top, state.notch.height)
                    .id(state.content.key)
                    // Old content leaves quickly so the two barely overlap.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                            .animation(.easeOut(duration: 0.2 * slowmo).delay(0.05 * slowmo)),
                        removal: .opacity.animation(.easeOut(duration: 0.08 * slowmo))))
            }
            .frame(width: width, height: height, alignment: .top)
            .clipShape(shape)
            .opacity(state.showContent ? 1 : 0)

            if compact, let live = state.live {
                LiveWings(counts: live, notchWidth: state.notch.width)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenPanel(.agents) }
                    .transition(.opacity)
            }
        }
        // Pinned to the top so resizing the window never moves anything.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch state.content {
        case .player:
            PlayerView(player: player)
        case .message(let message):
            MessageView(message: message)
                .contentShape(Rectangle())
                .onTapGesture(perform: onMessageTap)
                .onHover(perform: onMessageHover)
        case .inbox:
            InboxView(history: history, watcher: watcher, onOpenThread: onOpenThread, onOpenEntry: onOpenEntry)
        case .calendar:
            AgendaView(agenda: agenda, onOpen: onOpenURL)
        case .agents:
            AgentsView(watcher: watcher, selected: state.selectedThread, onOpen: onOpenAgent)
        case .home:
            HomeView(
                agenda: agenda, player: player, watcher: watcher, history: history,
                keyboard: state.keyboard, open: onOpenPanel, join: onOpenURL)
        }
    }
}

struct MessageView: View {
    let message: Message

    var body: some View {
        HStack(spacing: 12) {
            MessageIcon(message: message)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let source = message.source {
                        Text(source)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                if let body = message.body {
                    // A newline splits a one-line status from a one-line detail.
                    let lines = body.split(separator: "\n", maxSplits: 1).map(String.init)
                    if lines.count == 2 {
                        Text(lines[0])
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Text(lines[1])
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    } else {
                        Text(body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

}

struct MessageIcon: View {
    let message: Message
    var size: CGFloat = 34

    var body: some View {
        if let picture = message.picture {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: message.image == nil ? .fit : .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        } else {
            Image(systemName: message.icon ?? "bell.fill")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(message.tint)
                .frame(width: size, height: size)
                .background(Circle().fill(message.tint.opacity(0.18)))
        }
    }
}

struct PlayerView: View {
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(player.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Equalizer(playing: player.playing, tint: player.tint)
            }
            Progress(player: player)
            HStack(spacing: 44) {
                control("backward.fill", size: 18) { player.send("previous track") }
                control(player.playing ? "pause.fill" : "play.fill", size: 26) { player.send("playpause") }
                control("forward.fill", size: 18) { player.send("next track") }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private var artwork: some View {
        Group {
            if let image = player.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Spotify.app")) }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct Progress: View {
    @ObservedObject var player: Player

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = player.position(at: context.date)
            let fraction = player.duration > 0 ? position / player.duration : 0
            HStack(spacing: 10) {
                Text(format(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Color.white).frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        player.seek(to: location.x / geo.size.width * player.duration)
                    }
                }
                .frame(height: 14)
                Text("-" + format(player.duration - position))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct Equalizer: View {
    var playing: Bool
    var tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: playing ? 5 + 14 * abs(sin(t * (2.1 + Double(i) * 0.8) + Double(i))) : 4)
                }
            }
            .frame(height: 20)
            .animation(.easeInOut(duration: 0.12), value: t)
        }
    }
}

