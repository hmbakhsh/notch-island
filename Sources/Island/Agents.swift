import AppKit
import SwiftUI

/// What the live indicator beside the notch shows.
struct LiveCounts: Equatable {
    var running: Int
    /// Questions, approvals and failures.
    var needs: Int
    /// Finished since you last looked.
    var done: Int
}

enum LiveLayout {
    /// Width of each wing beside the notch.
    static let wing: CGFloat = 42
    /// Height on screens without a notch.
    static let minHeight: CGFloat = 26
}

/// The wings either side of the notch while agents are active: a spinner with
/// how many are working on the left, how many need you (or are done) on the right.
struct LiveWings: View {
    let counts: LiveCounts
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if counts.running > 0 {
                    Spinner()
                    Text("\(counts.running)")
                }
            }
            .frame(width: LiveLayout.wing)
            Spacer(minLength: notchWidth)
            Group {
                if counts.needs > 0 {
                    badge("\(counts.needs)", color: .orange)
                } else if counts.done > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                        Text("\(counts.done)")
                    }
                    .foregroundStyle(Color.green)
                }
            }
            .frame(width: LiveLayout.wing)
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(.black)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 2)
            .background(Capsule().fill(color))
    }
}

struct Spinner: View {
    var size: CGFloat = 11

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(turn * 360))
        }
    }
}

// MARK: - Agents panel

enum AgentsLayout {
    static let rowHeight: CGFloat = 46
    static let maxRows = 7

    static func height(sections: Int, rows: Int) -> CGFloat {
        guard rows > 0 else { return 8 + SectionHeader.height + rowHeight + 14 }
        return 8 + CGFloat(sections) * SectionHeader.height + CGFloat(min(rows, maxRows)) * rowHeight + 14
    }
}

/// Live list of T3 threads that need you, are working, or finished unread.
struct AgentsView: View {
    @ObservedObject var watcher: T3Watcher
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = Self.groups(watcher)
            if groups.isEmpty {
                SectionHeader(text: "Agents")
                Text("No agents running")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .frame(height: AgentsLayout.rowHeight)
            }
            ForEach(groups, id: \.title) { group in
                SectionHeader(text: group.title, count: group.title == "Needs you" ? group.threads.count : nil)
                ForEach(group.threads) { thread in
                    AgentRow(thread: thread, onOpen: onOpen)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// Needs you, then working, then done; capped at maxRows overall.
    static func groups(_ watcher: T3Watcher) -> [(title: String, threads: [WaitingThread])] {
        let needs = watcher.waiting.filter { $0.needsInput || $0.reason == "failed" }
        let done = watcher.waiting.filter { $0.reason == "finished" }
        var left = AgentsLayout.maxRows
        var out: [(String, [WaitingThread])] = []
        for (title, list) in [("Needs you", needs), ("Working", watcher.running), ("Done", done)] where !list.isEmpty && left > 0 {
            out.append((title, Array(list.prefix(left))))
            left -= min(list.count, left)
        }
        return out.map { (title: $0.0, threads: $0.1) }
    }

    static func height(_ watcher: T3Watcher) -> CGFloat {
        let groups = groups(watcher)
        return AgentsLayout.height(sections: groups.count, rows: groups.reduce(0) { $0 + $1.threads.count })
    }
}

private struct AgentRow: View {
    let thread: WaitingThread
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                glyph.frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(detail(at: context.date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: AgentsLayout.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: onOpen)
        }
    }

    @ViewBuilder private var glyph: some View {
        switch thread.reason {
        case "running": Spinner(size: 13)
        case "question": icon("questionmark.bubble.fill", .orange)
        case "approval": icon("hand.raised.fill", .orange)
        case "failed": icon("xmark.octagon.fill", .red)
        default: icon("checkmark.circle.fill", .green)
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
    }

    /// "pulse · Opus 5.5 · 4m 12s" while working; the status line otherwise.
    private func detail(at now: Date) -> String {
        let project = thread.project.isEmpty || thread.project == "No project" ? nil : thread.project
        guard thread.running else { return [project, thread.status].compactMap { $0 }.joined(separator: " · ") }
        let elapsed = Int(now.timeIntervalSince(isoDate(thread.since)))
        let time = elapsed < 3600 ? String(format: "%dm %02ds", elapsed / 60, elapsed % 60)
            : "\(elapsed / 3600)h \(elapsed % 3600 / 60)m"
        return [project, prettyModel(thread.model), time].compactMap { $0 }.joined(separator: " · ")
    }
}
