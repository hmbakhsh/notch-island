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
        case .message(let m):
            if m.countdown != nil { return 70 }
            if m.copies == true { return 60 }
            if m.plain == true { return m.body == nil ? 42 : 56 }
            return m.body == nil ? 50 : 70
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
    /// The row highlighted with the arrow keys (a thread or an event id).
    @Published var selected: String?
    /// Caps Lock was pressed on a banner: it stays up and ⏎ opens it.
    @Published var armed = false
    /// Agents working or waiting: shown as wings beside the notch while closed.
    @Published var live: LiveCounts?
    /// Headphones that just connected: take over the wings for a few seconds.
    @Published var device: ConnectedDevice?
    /// Spotify is playing: its cover and a wave sit in the wings.
    @Published var music = false

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
        let compact = !state.open && (state.live != nil || state.device != nil || state.music)
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

            if compact, let device = state.device {
                DeviceWings(device: device, notchWidth: state.notch.width)
                    .frame(width: width, height: height)
                    .transition(.opacity)
            } else if compact, state.music {
                MusicWings(
                    player: player, live: state.live, notchWidth: state.notch.width,
                    openPlayer: { onOpenPanel(.player) }, openAgents: { onOpenPanel(.agents) })
                    .frame(width: width, height: height)
                    .transition(.opacity)
            } else if compact, let live = state.live {
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
            MessageView(message: message, armed: state.armed)
                .contentShape(Rectangle())
                .onTapGesture(perform: onMessageTap)
                .onHover(perform: onMessageHover)
        case .inbox:
            InboxView(history: history, selected: state.selected, onOpenEntry: onOpenEntry)
        case .calendar:
            AgendaView(agenda: agenda, selected: state.selected, onOpen: onOpenURL)
        case .agents:
            AgentsView(watcher: watcher, selected: state.selected, onOpen: onOpenAgent)
        case .home:
            HomeView(
                agenda: agenda, player: player, watcher: watcher, history: history,
                keyboard: state.keyboard, open: onOpenPanel, join: onOpenURL)
        }
    }
}

struct MessageView: View {
    let message: Message
    var armed = false

    var body: some View {
        if message.copies == true, let code = message.pill {
            codeBody(code)
        } else if let repo = message.repo {
            agentBody(repo: repo)
        } else {
            standardBody
        }
    }

    /// Pinned with Caps Lock: a faint ↩ on the right says ⏎ will open it.
    @ViewBuilder private var returnHint: some View {
        if armed {
            Image(systemName: "return")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .transition(.opacity)
        }
    }

    /// An agent, on one line: status symbol, thread name, then its repo.
    private func agentBody(repo: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: message.icon ?? "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(message.tint)
            Text(message.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 10)
            if repo.isEmpty {
                Text("No repo")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.3))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                    Text(repo).font(.system(size: 12)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize()
            }
            returnHint
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    /// A verification code, AutoFill-style: the code centred, "From Fountain" under it.
    private func codeBody(_ code: String) -> some View {
        VStack(spacing: 2) {
            Text(code)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .tracking(4)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("From \(message.title)")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var standardBody: some View {
        HStack(spacing: 12) {
            if message.plain != true { MessageIcon(message: message) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let source = message.source, message.mirroredFrom == nil, !armed {
                        // Mirrored banners skip it: the app's icon already says
                        // where it's from, and the channel is the title.
                        Text(source)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                if let start = message.countdown {
                    Countdown(start: Date(timeIntervalSince1970: start), tint: message.tint)
                    if let body = message.body {
                        Text(body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                } else if let body = message.body {
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
                    } else if message.plain == true {
                        Text(body)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(message.color == nil ? .white.opacity(0.6) : message.tint)
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
            returnHint
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

}

/// "Starts in 1:45", ticking; "Started 0:20 ago" once it has.
struct Countdown: View {
    let start: Date
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(start.timeIntervalSince(context.date).rounded())
            Text(left > 0 ? "Starts in \(clock(left))" : left > -60 ? "Starting now" : "Started \(clock(-left)) ago")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }

    private func clock(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : String(format: "%d:%02d", s / 60, s % 60)
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


/// The wings while Spotify plays: the cover left, agents right. Agents
/// matter more, so the right wing shows the most urgent of: threads needing
/// you, threads working, threads finished unread; the music's wave only when
/// no agent is active.
struct MusicWings: View {
    @ObservedObject var player: Player
    let live: LiveCounts?
    let notchWidth: CGFloat
    let openPlayer: () -> Void
    let openAgents: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let image = player.artwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.15)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: LiveLayout.wing)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: openPlayer)
            Spacer(minLength: notchWidth)
            agents
                .frame(width: LiveLayout.wing)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { live == nil ? openPlayer() : openAgents() }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
    }

    @ViewBuilder private var agents: some View {
        if let live, live.needs > 0 {
            Text("\(live.needs)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.black)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, 2)
                .background(Capsule().fill(Color.orange))
        } else if let live, live.running > 0 {
            HStack(spacing: 4) {
                Spinner()
                Text("\(live.running)")
            }
        } else if let live, live.done > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                Text("\(live.done)")
            }
            .foregroundStyle(Color.green)
        } else {
            Equalizer(playing: player.playing, tint: player.tint)
                .scaleEffect(0.8)
        }
    }
}
