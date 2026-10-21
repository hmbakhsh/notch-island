import AppKit
import Carbon

/// Caps Lock as the island's key. Caps Lock is remapped to F18 (a key Mac
/// keyboards don't have) with hidutil, and F18 is registered as a global hot
/// key, so neither step needs Accessibility or Input Monitoring permission.
/// Opt in with "capsLockTrigger": true in the config.
enum Trigger {
    private static let capsLock: UInt64 = 0x7_0000_0039
    private static let f18: UInt64 = 0x7_0000_006D
    private static var action: (() -> Void)?
    private static var hotKey: EventHotKeyRef?

    static func install(_ action: @escaping () -> Void) {
        remapCapsLock()
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Trigger.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4E54_4348), id: 1)  // "NTCH"
        let status = RegisterEventHotKey(UInt32(kVK_F18), 0, id, GetApplicationEventTarget(), 0, &hotKey)
        log("Caps Lock trigger registered, status \(status)")
    }

    /// Adds Caps Lock → F18 to the user's key mappings, keeping any others.
    /// Lasts until logout; Island reapplies it every launch.
    private static func remapCapsLock() {
        let current = hidutil(["property", "--get", "UserKeyMapping"])
        var pairs: [(UInt64, UInt64)] = []
        let pattern = #"Dst = (\d+);\s*HIDKeyboardModifierMappingSrc = (\d+);"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: current, range: NSRange(current.startIndex..., in: current)) {
            guard let dst = Range(match.range(at: 1), in: current).flatMap({ UInt64(current[$0]) }),
                  let src = Range(match.range(at: 2), in: current).flatMap({ UInt64(current[$0]) }),
                  src != capsLock
            else { continue }
            pairs.append((src, dst))
        }
        pairs.append((capsLock, f18))
        let json = pairs
            .map { #"{"HIDKeyboardModifierMappingSrc":\#($0.0),"HIDKeyboardModifierMappingDst":\#($0.1)}"# }
            .joined(separator: ",")
        _ = hidutil(["property", "--set", #"{"UserKeyMapping":[\#(json)]}"#])
    }

    @discardableResult
    private static func hidutil(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
