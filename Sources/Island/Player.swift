import AppKit
import SwiftUI

let spotifyName = Notification.Name("com.spotify.client.PlaybackStateChanged")

final class Player: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var playing = false
    @Published var duration: Double = 0
    @Published var artwork: NSImage?
    @Published var tint = Color.white
    private var position: Double = 0
    private var positionAt = Date()
    private var artURL = ""

    func position(at date: Date) -> Double {
        let p = playing ? position + date.timeIntervalSince(positionAt) : position
        return min(max(p, 0), duration)
    }

    func refresh() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            playing = false
            return
        }
        let fields = run("""
            tell application "Spotify"
              if player state is stopped then return "stopped"
              set t to current track
              return (player state as text) & tab & name of t & tab & artist of t & tab & artwork url of t ¬
                & tab & (duration of t as text) & tab & (player position as text)
            end tell
            """).components(separatedBy: "\t")
        guard fields.count == 6 else {
            playing = false
            return
        }
        playing = fields[0] == "playing"
        title = fields[1]
        artist = fields[2]
        duration = (Double(fields[4]) ?? 0) / 1000
        position = Double(fields[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        positionAt = Date()
        if fields[3] != artURL {
            artURL = fields[3]
            loadArtwork(fields[3])
        }
    }

    func send(_ command: String) {
        run("tell application \"Spotify\" to \(command)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.refresh() }
    }

    func seek(to seconds: Double) {
        send("set player position to \(Int(seconds))")
    }

    @discardableResult
    private func run(_ source: String) -> String {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
    }

    private func loadArtwork(_ string: String) {
        guard let url = URL(string: string) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            let tint = accentColor(of: image)
            DispatchQueue.main.async {
                self.artwork = image
                self.tint = tint
            }
        }.resume()
    }
}

/// The cover's average colour, lifted so it reads on black.
func accentColor(of image: NSImage) -> Color {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    let avg = NSColor(
        red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    return Color(nsColor: NSColor(
        hue: avg.hueComponent,
        saturation: min(1, avg.saturationComponent * 1.4 + 0.1),
        brightness: max(0.8, avg.brightnessComponent),
        alpha: 1))
}
