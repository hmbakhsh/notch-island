import AppKit

// Releases, updates and migrations. A release is a tag: CI builds Island.zip
// and publishes it as the latest GitHub release (see release.sh). install.sh
// installs or updates from it; the running app updates itself every 6 hours
// while the island is closed, then restarts into the new version.

/// $HOME rather than the account's home folder, so installs can be tested in a throwaway HOME.
private let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
private let stateDir = ProcessInfo.processInfo.environment["ISLAND_STATE_DIR"] ?? "\(home)/.local/state/notch"

enum Install {
    static let repo = "hmbakhsh/notch-island"
    static let bundleID = "dev.notchisland.Island"
    static let label = "dev.notchisland.island"
    /// This copy of Island.app, also when run through the `notch` symlink.
    static let appPath = Bundle.main.executableURL.map {
        $0.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    } ?? Bundle.main.bundlePath
    static let version = Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Built from source (`just install`): updated by pulling and installing again, never from releases.
    static let isDev = version.hasPrefix("dev")
    static let agentPlist = "\(home)/Library/LaunchAgents/\(label).plist"
    static let cli = "\(home)/.local/bin/notch"

    /// Running from an installed Island.app, not `swift run` or build/.
    static var installed: Bool {
        appPath.hasSuffix(".app") && !appPath.contains("/build/") && !appPath.contains("/.build/")
    }

    /// Converge checks, then data migrations. Runs first on every start, and
    /// from install.sh (`Island --migrate`). Returns an error to show, if any.
    static func migrate() -> String? {
        converge()
        do {
            try Migrations.run()
            return nil
        } catch {
            log("migration failed: \(error)")
            return "Island couldn't update its data. See \(stateDir)/island.log"
        }
    }

    /// Repairs the install whatever state it's in: older copies moved to the
    /// Trash, the login item and `notch` pointing at this copy.
    static func converge() {
        guard installed else { return }
        let fm = FileManager.default
        let executable = "\(appPath)/Contents/MacOS/Island"

        // Copies an older install left behind: wherever the login item or `notch`
        // pointed (APP_DIR could move it), plus both Applications folders.
        var others = ["/Applications/Island.app", "\(home)/Applications/Island.app"]
        if let old = (NSDictionary(contentsOfFile: agentPlist)?["ProgramArguments"] as? [String])?.first {
            others.append(bundle(of: old))
        }
        if let old = try? fm.destinationOfSymbolicLink(atPath: cli) { others.append(bundle(of: old)) }
        for path in Set(others) where path != appPath && Bundle(path: path)?.bundleIdentifier == bundleID {
            let trash = "\(home)/.Trash/Island \(Int(Date().timeIntervalSince1970)).app"
            try? fm.createDirectory(atPath: "\(home)/.Trash", withIntermediateDirectories: true)
            do {
                try fm.moveItem(atPath: path, toPath: trash)
                log("moved an older copy to the Trash: \(path)")
            } catch {
                log("couldn't move \(path) to the Trash: \(error)")
            }
        }

        // The login item starts this copy. Picked up at the next login, or by install.sh now.
        let agent: NSDictionary = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        if NSDictionary(contentsOfFile: agentPlist) != agent {
            try? fm.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
            if agent.write(toFile: agentPlist, atomically: true) { log("wrote \(agentPlist)") }
        }

        // `notch` follows this copy when it points at another one.
        if let target = try? fm.destinationOfSymbolicLink(atPath: cli),
           target != executable, target.hasSuffix(".app/Contents/MacOS/Island") {
            try? fm.removeItem(atPath: cli)
            try? fm.createSymbolicLink(atPath: cli, withDestinationPath: executable)
            log("pointed \(cli) at \(executable)")
        }
    }

    private static func bundle(of executable: String) -> String {
        executable.components(separatedBy: "/Contents/MacOS/").first ?? executable
    }

    /// The new version, once, on the first start after an update.
    static func justUpdated() -> String? {
        let file = "\(stateDir)/version"
        let last = (try? String(contentsOfFile: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? version.write(toFile: file, atomically: true, encoding: .utf8)
        guard let last, last != version, !isDev else { return nil }
        return version
    }

    /// Hands over to the new binary: launchd restarts the login item (killing
    /// this process if it is the login item); otherwise the app is reopened.
    static func restart() -> Never {
        close(lock)
        if shell("launchctl kickstart -k gui/\(getuid())/\(label)") != 0 {
            shell("open -n '\(appPath)'")
        }
        exit(0)
    }
}

/// One-way changes to user data (config, history), oldest first, each with the
/// version it ships in. Every start runs those newer than `migrated-version` and
/// records each as it succeeds; a failure stops there and is retried next start.
/// Keep old ones: someone may update from any older version. A missing file means
/// an install from before 0.1.0, so check for the old layout rather than assume
/// a fresh one. Back up anything changed, and move rather than delete.
enum Migrations {
    static let all: [(version: String, run: () throws -> Void)] = []

    static func run() throws {
        let file = "\(stateDir)/migrated-version"
        var done = (try? String(contentsOfFile: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        for migration in all where migration.version.compare(done, options: .numeric) == .orderedDescending {
            try migration.run()
            done = migration.version
            try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            try done.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }
}

enum Updater {
    static let checkEvery: TimeInterval = 6 * 3600

    /// The newest release if it's newer than this one. Follows github.com's
    /// /releases/latest redirect (…/tag/vX.Y.Z); unlike the API it isn't rate-limited.
    static func newer() async -> String? {
        guard Install.installed, !Install.isDev,
              let url = URL(string: "https://github.com/\(Install.repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let final = response.url, final.path.contains("/tag/") else { return nil }
        let latest = final.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        return latest.compare(Install.version, options: .numeric) == .orderedDescending ? latest : nil
    }

    /// Updates the way it was installed: through Homebrew for the cask,
    /// otherwise the release zip is swapped in over this copy.
    static var command: String {
        if let brew = ["/opt/homebrew", "/usr/local"]
            .first(where: { FileManager.default.fileExists(atPath: "\($0)/Caskroom/notch-island") }) {
            return "'\(brew)/bin/brew' update --quiet && '\(brew)/bin/brew' upgrade --cask notch-island"
        }
        return """
            set -e; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
            curl -fsSL https://github.com/\(Install.repo)/releases/latest/download/Island.zip -o "$T/Island.zip"
            ditto -x -k "$T/Island.zip" "$T"
            rm -rf '\(Install.appPath)' && ditto "$T/Island.app" '\(Install.appPath)'
            """
    }

    /// Installs it over this copy; the caller then restarts into it.
    static func apply(_ version: String) -> Bool {
        log("updating to \(version)")
        guard shell(command) == 0 else {
            log("update to \(version) failed")
            return false
        }
        return true
    }
}

/// Runs `command` with bash; its output goes to island.log.
@discardableResult
func shell(_ command: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let logFile = "\(stateDir)/island.log"
    if !FileManager.default.fileExists(atPath: logFile) { FileManager.default.createFile(atPath: logFile, contents: nil) }
    let output = FileHandle(forWritingAtPath: logFile)
    output?.seekToEndOfFile()
    process.standardOutput = output
    process.standardError = output
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}
