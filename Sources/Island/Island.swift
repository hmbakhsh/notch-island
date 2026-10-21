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
    let agenda = Agenda()
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
    private var hoverTimer: Timer?
    private var hoverSince: Date?
    private var hoverLeftAt: Date?
    /// Opened from the keyboard, so moving the mouse doesn't close it.
    private var homePinned = false

    init() {
        panel = IslandPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = FirstClickHost(rootView: IslandView(
            state: state, player: player, history: history, watcher: watcher, agenda: agenda,
            onMessageTap: { [weak self] in self?.tapMessage() },
            onMessageHover: { [weak self] inside in self?.hoverMessage(inside) },
            onOpenThread: { [weak self] in
                if let url = t3AppURL { NSWorkspace.shared.open(url) }
                self?.close()
            },
            onOpenEntry: { [weak self] entry in
                entry.message.perform()
                self?.close()
            },
            onOpenURL: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onOpenPanel: { [weak self] panel in self?.toggle(panel) }))
        // The island sizes the window itself; don't let SwiftUI resize it too.
        host.sizingOptions = []
        panel.contentView = host

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
        center.addObserver(forName: calendarName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.calendar)
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
        center.addObserver(forName: homeName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.home)
        }
        if Config.shared.capsLockTrigger == true {
            Trigger.install { [weak self] in self?.toggle(.home) }
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkHover()
        }
        player.refresh()
        updateBar()
    }

    // MARK: Panels opened from the bar

    enum Panel { case player, inbox, calendar, home }

    private var openPanel: Panel? {
        guard state.open else { return nil }
        switch state.content {
        case .player: return .player
        case .inbox: return .inbox
        case .calendar: return .calendar
        case .home: return .home
        case .message: return nil
        }
    }

    private func toggle(_ panel: Panel) {
        if openPanel == panel || (panel == .home && openPanel != nil) {
            // The trigger key closes whatever panel is open.
            close()
        } else if case .home = state.content, state.open {
            content(for: panel) { [weak self] content in
                self?.morph(to: content)
                self?.watchOutsideClicks()
            }
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
        content(for: panel) { [weak self] content in
            guard let self, !self.busy else { return }
            self.present(content)
            self.watchOutsideClicks()
        }
    }

    /// Loads what a panel needs, then hands back its content. Calendar waits
    /// for the permission prompt the first time.
    private func content(for panel: Panel, _ done: @escaping (Content) -> Void) {
        switch panel {
        case .player:
            player.refresh()
            done(.player)
        case .inbox:
            history.markRead()
            updateBar()
            done(.inbox(height: InboxLayout.height(waiting: watcher.waiting.count, recent: history.entries.count)))
        case .calendar:
            agenda.refresh { [weak self] in
                guard let self else { return }
                done(.calendar(height: AgendaLayout.height(events: self.agenda.events, access: self.agenda.access)))
            }
        case .home:
            agenda.reloadIfAllowed()
            player.refresh()
            homePinned = true
            state.keyboard = Config.shared.capsLockTrigger == true
            if state.keyboard { Trigger.captureNumbers { [weak self] n in self?.pressNumber(n) } }
            done(.home)
        }
    }

    /// 1: join the next call, or open the calendar. 2: bring T3 forward if
    /// threads are waiting, or open the inbox. 3: play/pause.
    private func pressNumber(_ n: Int) {
        guard case .home = state.content, state.open else { return }
        switch n {
        case 1:
            if let url = agenda.events.first?.joinURL {
                NSWorkspace.shared.open(url)
                close()
            } else {
                toggle(.calendar)
            }
        case 2:
            if !watcher.waiting.isEmpty, let t3 = t3AppURL {
                NSWorkspace.shared.open(t3)
                close()
            } else {
                toggle(.inbox)
            }
        case 3:
            player.send("playpause")
        default:
            break
        }
    }

    // MARK: Hover

    /// Resting on the notch opens the overview; leaving it closes it again.
    private func checkHover() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        if case .home = state.content, state.open {
            guard !homePinned else { return }
            let inside = NSMouseInRect(mouse, islandFrame, false)
                || panel.screen.map { NSMouseInRect(mouse, hotZone(on: $0), false) } == true
            if inside {
                hoverLeftAt = nil
            } else if let left = hoverLeftAt {
                if now.timeIntervalSince(left) > 0.3 { hoverLeftAt = nil; close() }
            } else {
                hoverLeftAt = now
            }
            return
        }

        guard !busy, NSEvent.pressedMouseButtons == 0,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              NSMouseInRect(mouse, hotZone(on: screen), false)
        else {
            hoverSince = nil
            return
        }
        if let since = hoverSince {
            if now.timeIntervalSince(since) > 0.15 {
                hoverSince = nil
                showHome()
            }
        } else {
            hoverSince = now
        }
    }

    private func showHome() {
        agenda.reloadIfAllowed()
        player.refresh()
        hoverLeftAt = nil
        homePinned = false
        state.keyboard = false
        present(.home)
    }

    /// The notch itself, or a strip at the top centre of screens without one.
    private func hotZone(on screen: NSScreen) -> NSRect {
        let notch = notchSize(of: screen)
        let width = notch.height > 0 ? notch.width : 200
        let height = max(notch.height, 4)
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height + 1)
    }

    /// The visible island, without the panel's shadow margin.
    private var islandFrame: NSRect {
        let height = state.notch.height + state.content.height
        return NSRect(x: panel.frame.midX - islandWidth / 2, y: panel.frame.maxY - height, width: islandWidth, height: height + 1)
    }

    private func watchOutsideClicks() {
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
        withAnimation(.spring(response: 0.32 * slowmo, dampingFraction: 0.82)) { state.open = true }
        withAnimation(.easeOut(duration: 0.18 * slowmo).delay(0.04 * slowmo)) { state.showContent = true }
    }

    /// Grows (or shrinks) the open island into other content without closing.
    private func morph(to content: Content) {
        releaseNumbers()
        // Grow the window first (it's transparent), shrink it only once the
        // shape has finished, so the window edge never cuts the animation.
        setFrame(contentHeight: max(content.height, state.content.height))
        withAnimation(.spring(response: 0.34 * slowmo, dampingFraction: 0.86)) { state.content = content }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * slowmo) { [weak self] in
            guard let self, self.state.open, self.state.content.key == content.key else { return }
            self.setFrame(contentHeight: content.height)
        }
    }

    /// Resizes the panel in place, keeping it pinned to the top of its screen.
    private func setFrame(contentHeight: CGFloat) {
        let height = state.notch.height + contentHeight + shadowRoom
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func releaseNumbers() {
        guard state.keyboard else { return }
        state.keyboard = false
        Trigger.captureNumbers(nil)
    }

    private func close() {
        guard state.open else { return }
        releaseNumbers()
        dismissTimer?.cancel()
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        withAnimation(.easeIn(duration: 0.12 * slowmo)) { state.showContent = false }
        withAnimation(.spring(response: 0.28 * slowmo, dampingFraction: 1)) { state.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32 * slowmo) { [weak self] in
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
