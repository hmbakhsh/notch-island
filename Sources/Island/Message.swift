import AppKit
import SwiftUI

let spotifyToggleName = Notification.Name("dev.notchisland.spotify")
let messageName = Notification.Name("dev.notchisland.message")
let dismissName = Notification.Name("dev.notchisland.dismiss")
let inboxName = Notification.Name("dev.notchisland.inbox")
let calendarName = Notification.Name("dev.notchisland.calendar")
let homeName = Notification.Name("dev.notchisland.home")
let agentsName = Notification.Name("dev.notchisland.agents")
let devicePreviewName = Notification.Name("dev.notchisland.device-preview")
let mirrorReplayName = Notification.Name("dev.notchisland.mirror-replay")
let settingsName = Notification.Name("dev.notchisland.settings")

struct Message: Codable {
    var title = ""
    var body: String?
    var source: String?
    var icon: String?
    var app: String?
    var image: String?
    var color: String?
    /// nil → the configured default (8s), 0 → stays until clicked.
    var seconds: Double?
    var open: String?
    var run: String?
    var sound: String?
    /// Set for notifications mirrored from another app (its bundle id), so
    /// bursts from the same app can be merged.
    var mirroredFrom: String?
    /// No icon: just the text, with the body tinted by `color`.
    var plain: Bool?
    var mergedCount: Int?
    /// Seconds since 1970 of something about to start (a meeting): the banner
    /// counts down to it above the body.
    var countdown: Double?

    var tint: Color {
        let named: [String: Color] = [
            "red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "mint": .mint,
    /// A mirrored Slack notification's id ("T<team>_<ts>"), to find its channel.
    var slackID: String?
    /// A verification code: shown large on the right; clicking copies it.
    var code: String?
            "teal": .teal, "cyan": .cyan, "blue": .blue, "indigo": .indigo, "purple": .purple,
            "pink": .pink, "gray": .gray, "grey": .gray, "white": .white,
        ]
        guard let color = color?.lowercased() else { return .white }
        if let c = named[color] { return c }
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return .white }
        return Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    /// An app icon or image file, if one was asked for.
    var picture: NSImage? {
        if let image, image.hasPrefix("app:") { return NSWorkspace.shared.icon(forFile: String(image.dropFirst(4))) }
        if let image { return NSImage(contentsOfFile: (image as NSString).expandingTildeInPath) }
        guard let app else { return nil }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "~/Applications"]
        for dir in dirs {
            let path = (dir as NSString).expandingTildeInPath + "/\(app).app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }

    func perform() {
        if let slackID, let url = Slack.channelLink(notification: slackID) {
            NSWorkspace.shared.open(url)
        } else if let open {
            let url = URL(string: open).flatMap { $0.scheme == nil ? nil : $0 }
                ?? URL(fileURLWithPath: (open as NSString).expandingTildeInPath)
            if url.scheme?.hasPrefix("t3code") == true {
                T3.open(link: url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        if let run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", run]
            try? process.run()
        }
    }
}

/// The sending side: the CLI posts to the running agent, starting it if needed.
enum Agent {
    static func post(_ name: Notification.Name, json: String? = nil) {
        ensureRunning()
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: json.map { ["json": $0] }, deliverImmediately: true)
    }

    private static func ensureRunning() {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "Island"]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        guard pgrep.terminationStatus != 0, let me = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return }

        // Inside Island.app, launch the app so macOS attributes permissions to
        // it; a bare build (swift run, just build) is started directly.
        let app = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let launcher = Process()
        if app.pathExtension == "app" {
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = ["-g", "-j", app.path]
        } else {
            launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            launcher.arguments = ["-c", "nohup \"$0\" >/dev/null 2>&1 &", me.path]
        }
        try? launcher.run()
        launcher.waitUntilExit()
        usleep(800_000)  // let it subscribe before we post
    }
}

enum Notify {
    static func run(_ args: [String]) -> Never {
        var message = Message()
        var positional: [String] = []
        var i = 0

        func fail(_ text: String) -> Never {
            FileHandle.standardError.write(Data("notch: \(text)\n".utf8))
            exit(64)
        }
        func value() -> String {
            i += 1
            guard i < args.count else { fail("\(args[i - 1]) needs a value") }
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-b", "--body": message.body = value()
            case "-s", "--source": message.source = value()
            case "-i", "--icon": message.icon = value()
            case "-a", "--app": message.app = value()
            case "--image": message.image = value()
            case "-c", "--color": message.color = value()
            case "-t", "--time":
                guard let t = Double(value()) else { fail("--time takes seconds") }
                message.seconds = t
            case "--sticky": message.seconds = 0
            case "--plain": message.plain = true
            case "-o", "--open": message.open = value()
            case "-r", "--run": message.run = value()
            case "--sound": message.sound = value()
            case "--json":
                let v = value()
                let data = v == "-" ? FileHandle.standardInput.readDataToEndOfFile() : Data(v.utf8)
                do { message = try JSONDecoder().decode(Message.self, from: data) } catch { fail("bad JSON: \(error)") }
            case "--inbox":
                Agent.post(inboxName)
                exit(0)
            case "--spotify":
                Agent.post(spotifyToggleName)
                exit(0)
            case "--calendar":
                Agent.post(calendarName)
                exit(0)
            case "--home":
                Agent.post(homeName)
                exit(0)
            case "--agents":
                Agent.post(agentsName)
                exit(0)
            case "--settings":
                Agent.post(settingsName)
                exit(0)
            case "--replay-notification":
                Agent.post(mirrorReplayName)
                exit(0)
            case "--preview-device":
                Agent.post(devicePreviewName, json: value())
                exit(0)
            case "--dismiss":
                Agent.post(dismissName)
                exit(0)
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                if arg.hasPrefix("-"), arg.count > 1 { fail("unknown option \(arg)\n\n\(usage)") }
                positional.append(arg)
            }
            i += 1
        }
        if let title = positional.first { message.title = title }
        if positional.count > 1, message.body == nil { message.body = positional[1] }
        guard !message.title.isEmpty else { fail("a title is required\n\n\(usage)") }

        let json = String(decoding: try! JSONEncoder().encode(message), as: UTF8.self)
        Agent.post(messageName, json: json)
        exit(0)
    }
}

/// Appends a line to island.log next to the history, for debugging.
func log(_ line: String) {
    let dir = ProcessInfo.processInfo.environment["ISLAND_STATE_DIR"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/notch")
    let url = URL(fileURLWithPath: dir).appendingPathComponent("island.log")
    let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: url)
    }
}
