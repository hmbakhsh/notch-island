import AppKit
import IOBluetooth
import SwiftUI

/// A headphone that just connected, shown iOS-style in the wings.
struct ConnectedDevice: Equatable {
    let name: String
    let symbol: String
    /// 0...1 once known (the lower of the two buds for AirPods).
    var battery: Double?
}

/// Watches for Bluetooth headphones connecting (AirPods, Beats, any audio
/// device) and reads their battery from system_profiler, since macOS has no
/// public API for AirPods battery.
final class DeviceWatcher: NSObject {
    var onConnect: ((ConnectedDevice) -> Void)?
    var onBattery: ((String, Double) -> Void)?
    private var notification: IOBluetoothUserNotification?
    private let started = Date()

    func start() {
        notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Devices already connected are reported when Island starts; skip those.
        guard Date().timeIntervalSince(started) > 5, let name = device.name else { return }
        let headphones = device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
            || name.localizedCaseInsensitiveContains("airpods") || name.localizedCaseInsensitiveContains("beats")
        guard headphones else { return }
        onConnect?(ConnectedDevice(name: name, symbol: Self.symbol(for: name), battery: nil))

        // AirPods report battery a moment after connecting.
        for delay in [1.0, 3.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                guard let level = Self.battery(of: name) else { return }
                DispatchQueue.main.async { self.onBattery?(name, level) }
            }
        }
    }

    /// Shows the connect animation for a made-up device, for previews.
    func preview(_ name: String) {
        onConnect?(ConnectedDevice(name: name, symbol: Self.symbol(for: name), battery: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.onBattery?(name, 0.82) }
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpods.pro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        return "headphones"
    }

    /// Battery from system_profiler: the lower bud for AirPods, else the main level.
    private static func battery(of name: String) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }
        for block in blocks {
            for device in block["device_connected"] as? [[String: [String: Any]]] ?? [] {
                guard let info = device[name] else { continue }
                func level(_ key: String) -> Double? {
                    (info[key] as? String).flatMap { Double($0.filter(\.isNumber)) }.map { $0 / 100 }
                }
                let buds = [level("device_batteryLevelLeft"), level("device_batteryLevelRight")].compactMap { $0 }
                return buds.min() ?? level("device_batteryLevelMain")
            }
        }
        return nil
    }
}

/// The wings while a device connects: its icon left, a battery ring right.
struct DeviceWings: View {
    let device: ConnectedDevice
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: device.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: LiveLayout.wing)
            Spacer(minLength: notchWidth)
            BatteryRing(level: device.battery)
                .frame(width: LiveLayout.wing)
        }
    }
}

private struct BatteryRing: View {
    let level: Double?

    var body: some View {
        let value = level ?? 0
        // Grey until the level is known, then green (red when low).
        let color: Color = level == nil ? .white.opacity(0.5) : value <= 0.2 ? .red : .green
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: value)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 17, height: 17)
        .animation(.easeOut(duration: 0.6), value: value)
    }
}
