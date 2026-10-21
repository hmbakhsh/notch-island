import AppKit
import SwiftUI

let slowmo = Double(ProcessInfo.processInfo.environment["ISLAND_SLOWMO"] ?? "") ?? 1

final class FirstClickHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless windows are normally kept below the menu bar; the island has
/// to sit in it, over the notch.
final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the panel and decides what it shows: the Spotify player on request,
/// otherwise queued messages one at a time.
final class Island {
    let player = Player()
    let history = History()
    let watcher = T3Watcher()
    let state = IslandState()
    let panel: IslandPanel
    private var queue: [Message] = []
    /// From the start of opening until the panel is ordered out.
    private var busy = false
    /// A panel asked for while a message was up; shown once it has gone.
    private var requested: Panel?
    private var outsideClickMonitor: Any?
    private var closedByOutsideClickAt = Date.distantPast
    private var dismissTimer: DispatchWorkItem?

    init() {
        panel = IslandPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstClickHost(rootView: IslandView(
            state: state, player: player, history: history, watcher: watcher,
            onMessageTap: { [weak self] in self?.tapMessage() },
            onMessageHover: { [weak self] inside in self?.hoverMessage(inside) },
            onOpenThread: { [weak self] in
                if let url = t3AppURL { NSWorkspace.shared.open(url) }
                self?.close()
            },
            onOpenEntry: { [weak self] entry in
                entry.message.perform()
                self?.close()
            }))

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: spotifyName, object: nil, queue: .main) { [weak self] _ in
            self?.player.refresh()
        }
        center.addObserver(forName: spotifyToggleName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.player)
        }
        center.addObserver(forName: inboxName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.inbox)
        }
        center.addObserver(forName: messageName, object: nil, queue: .main) { [weak self] note in
            guard let json = note.userInfo?["json"] as? String,
                  let message = try? JSONDecoder().decode(Message.self, from: Data(json.utf8))
            else { return }
            self?.deliver(message)
        }
        center.addObserver(forName: dismissName, object: nil, queue: .main) { [weak self] _ in
            guard let self, case .message = self.state.content else { return }
            self.close()
        }
        watcher.onNew = { [weak self] thread in self?.deliver(thread.message) }
        watcher.onChange = { [weak self] in self?.updateBar() }
        watcher.start()
        player.refresh()
        updateBar()
    }

    // MARK: Panels opened from the bar

    enum Panel { case player, inbox }

    private var openPanel: Panel? {
        guard state.open else { return nil }
        switch state.content {
        case .player: return .player
        case .inbox: return .inbox
        case .message: return nil
        }
    }

    private func toggle(_ panel: Panel) {
        if openPanel == panel {
            close()
        } else if Date().timeIntervalSince(closedByOutsideClickAt) < 0.4 {
            // A click on the bar item also counts as an outside click; that
            // click already closed us, so don't reopen.
        } else if busy {
            // Something else is up; swap once it has gone.
            requested = panel
            close()
        } else {
            show(panel)
        }
    }

    private func show(_ panel: Panel) {
        switch panel {
        case .player:
            player.refresh()
            present(.player)
        case .inbox:
            history.markRead()
            updateBar()
            present(.inbox(height: InboxLayout.height(
                waiting: watcher.waiting.count, recent: history.entries.count)))
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.closedByOutsideClickAt = Date()
            self?.close()
        }
    }

    // MARK: Messages

    private func deliver(_ message: Message) {
        history.add(message)
        updateBar()
        queue.append(message)
        showNext()
    }

    /// Publishes counts for status bars: writes status.json next to the
    /// history, and fires sketchybar's `island_update` event (WAITING, UNREAD)
    /// if sketchybar is installed.
    private func updateBar() {
        let waiting = watcher.waiting.count
        let unread = history.unread
        let status = #"{"waiting": \#(waiting), "unread": \#(unread)}"#
        try? status.write(to: history.directory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)

        guard let sketchybar = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sketchybar)
        process.arguments = ["--trigger", "island_update", "WAITING=\(waiting)", "UNREAD=\(unread)"]
        try? process.run()
    }

    private func showNext() {
        guard !busy, !queue.isEmpty else { return }
        let message = queue.removeFirst()
        if let sound = message.sound { NSSound(named: sound == "default" ? "Glass" : sound)?.play() }
        present(.message(message))
        scheduleDismiss(after: message.seconds ?? 5)
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTimer?.cancel()
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hoverMessage(_ inside: Bool) {
        guard case .message(let message) = state.content, state.open else { return }
        if inside {
            dismissTimer?.cancel()
        } else if message.seconds != 0 {
            scheduleDismiss(after: 2)
        }
    }

    private func tapMessage() {
        guard case .message(let message) = state.content, state.open else { return }
        message.perform()
        close()
    }

    // MARK: Panel

    private func present(_ content: Content) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        busy = true
        let notch = notchSize(of: screen)
        let width = islandWidth + shadowRoom * 2
        let height = notch.height + content.height + shadowRoom
        panel.setFrame(
            NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height),
            display: false)

        state.notch = notch
        state.content = content
        state.open = false
        state.showContent = false
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.42 * slowmo, dampingFraction: 0.8)) { state.open = true }
        withAnimation(.easeOut(duration: 0.22 * slowmo).delay(0.16 * slowmo)) { state.showContent = true }
    }

    private func close() {
        guard state.open else { return }
        dismissTimer?.cancel()
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        withAnimation(.easeIn(duration: 0.1 * slowmo)) { state.showContent = false }
        withAnimation(.spring(response: 0.34 * slowmo, dampingFraction: 1).delay(0.06 * slowmo)) {
            state.open = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 * slowmo) { [weak self] in
            guard let self, !self.state.open else { return }
            self.panel.orderOut(nil)
            self.busy = false
            if let panel = self.requested {
                self.requested = nil
                self.show(panel)
            } else {
                // Leave a beat between messages so each one reads as new.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.showNext() }
            }
        }
    }

    /// The notch's size, or a zero-height sliver on screens without one so the
    /// island still grows out of the top edge.
    private func notchSize(of screen: NSScreen) -> CGSize {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return CGSize(width: 200, height: 0)
        }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }
}
