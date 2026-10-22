// Island: a Dynamic Island-style panel that grows out of the notch.
//
//   Island                 run the background agent (started at login)
//   notch TITLE [BODY] …   show a message (notch is a symlink to Island)
//   notch --inbox          open/close the inbox
//   notch --spotify        open/close the Spotify player
//   notch --calendar       open/close upcoming calendar events

import AppKit

let usage = """
    usage: notch TITLE [BODY] [options]
           notch --json '{"title": "…", "body": "…", …}'   (or --json - to read stdin)
           notch --dismiss                                 hide the message on screen now
           notch --inbox                                   open/close the inbox (history + waiting T3 threads)
           notch --spotify                                 open/close the Spotify player
           notch --calendar                                open/close upcoming calendar events
           notch --home                                    open/close the overview (bind it to any key)
           notch --agents                                  open/close the live list of T3 agents
           notch --settings                                open the settings window
           notch --preview-device "AirPods Pro"            preview the headphones-connected animation
           notch --replay-notification                     show the latest mirrored (e.g. Slack) notification again

    History is kept in ~/.local/state/notch/history.jsonl (one JSON entry per line).

    Shows a message that drops out of the notch. Messages queue; each hides
    after a few seconds, pauses while hovered, and is dismissed on click.
    With the Caps Lock trigger on, Caps pins the banner on screen: ⏎ opens it,
    Esc dismisses it.

      -b, --body TEXT       second line, wraps to two lines
      -s, --source TEXT     small label top-right, e.g. "Claude · api"
      -i, --icon NAME       SF Symbol, e.g. checkmark.circle.fill, exclamationmark.triangle.fill
      -a, --app NAME        use an app's icon instead, e.g. Claude, Slack
          --image PATH      use an image file instead
      -c, --color COLOR     icon tint: red orange yellow green mint teal blue indigo purple pink gray, or #RRGGBB
      -t, --time SECONDS    how long it stays (default 8, set in settings)
          --sticky          stay until clicked
          --plain           no icon; the body is tinted with --color instead
      -o, --open URL|PATH   open this on click
      -r, --run COMMAND     run this shell command on click
          --sound NAME      play a system sound, e.g. Glass, Ping, Submarine

    JSON keys match the long option names: title body source icon app image
    color seconds open run sound.
    """

let arguments = Array(CommandLine.arguments.dropFirst())

if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "notch" {
    Notify.run(arguments)
}
switch arguments.first {
case nil:
    break
case "notify":
    Notify.run(Array(arguments.dropFirst()))
case "spotify":
    Agent.post(spotifyToggleName)
    exit(0)
case "inbox":
    Agent.post(inboxName)
    exit(0)
case "-h", "--help":
    print(usage)
    exit(0)
default:
    FileHandle.standardError.write(Data("unknown command \(arguments[0])\n\n\(usage)\n".utf8))
    exit(64)
}

// One agent per user: the login item and `notch` may both try to start one.
let lockPath = (ProcessInfo.processInfo.environment["ISLAND_STATE_DIR"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/notch"))
try? FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: true)
let lock = open((lockPath as NSString).appendingPathComponent("island.lock"), O_CREAT | O_RDWR, 0o644)
if flock(lock, LOCK_EX | LOCK_NB) != 0 { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let island = Island()
app.delegate = island
app.run()
