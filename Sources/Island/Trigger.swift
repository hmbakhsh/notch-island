import AppKit
import Carbon

/// Caps Lock as the island's key. Caps Lock is remapped to F18 (a key Mac
/// keyboards don't have) with hidutil, and F18 is registered as a global hot
/// key, so neither step needs Accessibility or Input Monitoring permission.
/// Opt in with "capsLockTrigger": true in the config.
enum Trigger {
    private static let capsLock: UInt64 = 0x7_0000_0039
    private static let f18: UInt64 = 0x7_0000_006D
    private static let signature = OSType(0x4E54_4348)  // "NTCH"
    private static var action: (() -> Void)?
    private static var numberAction: ((Int) -> Void)?
    private static var hotKey: EventHotKeyRef?
    private static var numberKeys: [EventHotKeyRef] = []
    private static var escapeAction: (() -> Void)?
    private static var escapeKey: EventHotKeyRef?
    private static var listAction: ((ListKey) -> Void)?
    private static var listKeys: [EventHotKeyRef] = []

    enum ListKey { case up, down, open }
    private static var handlerInstalled = false
    private static var lastPress = Date.distantPast

    static func install(_ action: @escaping () -> Void) {
        remapCapsLock()
        Self.action = action
        installHandler()
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_F18), 0, id, GetApplicationEventTarget(), 0, &hotKey)
        log("Caps Lock trigger registered, status \(status)")
    }

    /// One Carbon handler for every hot key Island registers.
    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { Trigger.pressed(id.id) }
            return noErr
        }, 1, &spec, nil, nil)
        log("hot key handler installed, status \(installed)")
    }

    private static func pressed(_ id: UInt32) {
        if id == 1 {
            // Holding Caps Lock repeats; only a fresh press counts.
            let now = Date()
            defer { lastPress = now }
            guard now.timeIntervalSince(lastPress) > 0.3 else { return }
            action?()
        } else if id == 20 {
            escapeAction?()
        } else if id >= 30 {
            listAction?([ListKey.up, .down, .open][Int(id) - 30])
        } else {
            numberAction?(Int(id) - 10)
        }
    }

    /// Captures ↑ ↓ and ⏎ while a list is open from the keyboard, and gives
    /// them back as soon as it closes.
    static func captureList(_ handler: ((ListKey) -> Void)?) {
        listKeys.forEach { UnregisterEventHotKey($0) }
        listKeys = []
        listAction = handler
        guard handler != nil else { return }
        installHandler()
        for (n, key) in [kVK_UpArrow, kVK_DownArrow, kVK_Return].enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(30 + n))
            if RegisterEventHotKey(UInt32(key), 0, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                listKeys.append(ref)
            }
        }
    }

    /// Captures Esc everywhere while the island is open, and gives it back as
    /// soon as it closes.
    static func captureEscape(_ handler: (() -> Void)?) {
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        escapeKey = nil
        escapeAction = handler
        guard handler != nil else { return }
        installHandler()
        let id = EventHotKeyID(signature: signature, id: 20)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escapeKey)
    }

    /// Captures 1, 2 and 3 everywhere while the island is open from the
    /// keyboard, and gives them back as soon as it closes.
    static func captureNumbers(_ handler: ((Int) -> Void)?) {
        numberKeys.forEach { UnregisterEventHotKey($0) }
        numberKeys = []
        numberAction = handler
        guard handler != nil else { return }
        for (n, key) in [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(11 + n))
            if RegisterEventHotKey(UInt32(key), 0, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                numberKeys.append(ref)
            }
        }
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
        // System Settings → Modifier Keys may already send Caps Lock as another
        // key, and that mapping can run before ours. Map that key to F18 too,
        // but only right-side modifiers: built-in keyboards don't have them.
        for alias in settingsCapsLockTargets() where (0x7_0000_00E4...0x7_0000_00E7).contains(alias) {
            pairs.removeAll { $0.0 == alias }
            pairs.append((alias, f18))
            log("Caps Lock is set to send \(String(alias, radix: 16)) in System Settings; mapping that to F18 too")
        }
        let json = pairs
            .map { #"{"HIDKeyboardModifierMappingSrc":\#($0.0),"HIDKeyboardModifierMappingDst":\#($0.1)}"# }
            .joined(separator: ",")
        _ = hidutil(["property", "--set", #"{"UserKeyMapping":[\#(json)]}"#])
    }

    /// What System Settings → Modifier Keys sends for Caps Lock, per keyboard.
    private static func settingsCapsLockTargets() -> Set<UInt64> {
        let any = kCFPreferencesAnyApplication, user = kCFPreferencesCurrentUser, host = kCFPreferencesCurrentHost
        guard let keys = CFPreferencesCopyKeyList(any, user, host) as? [String] else { return [] }
        var targets = Set<UInt64>()
        for key in keys where key.hasPrefix("com.apple.keyboard.modifiermapping") {
            let mappings = CFPreferencesCopyValue(key as CFString, any, user, host) as? [[String: Any]] ?? []
            for m in mappings {
                guard let src = (m["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value,
                      let dst = (m["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value,
                      src == capsLock, dst != capsLock
                else { continue }
                targets.insert(dst)
            }
        }
        return targets
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
