import CoreGraphics
import CoreAudio
import CoreWLAN
import Foundation
import IOKit.ps
import Observation

/// Battery, Wi-Fi and output-volume readings for the taskbar's notification
/// area and its popup. Plain polling reads (cheap system calls); the owner
/// calls `refresh()` on a timer while the area is on screen.
@MainActor
@Observable
final class SystemStatus {
    static let shared = SystemStatus()

    struct Battery {
        var percent: Int
        var isCharging: Bool
        var isOnAC: Bool
        var minutesRemaining: Int?
    }

    private(set) var battery: Battery?
    private(set) var isWiFiOn = false
    private(set) var wifiName: String?
    private(set) var isWiFiConnected = false
    private(set) var volume: Float = 0
    private(set) var isMuted = false

    @ObservationIgnored private var timer: Timer?

    /// Starts the periodic refresh (once) while the notification area is
    /// on screen.
    func startPolling() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        battery = Self.readBattery()
        let interface = CWWiFiClient.shared().interface()
        isWiFiOn = interface?.powerOn() ?? false
        // `ssid()` is empty unless Location access was granted; the RSSI is
        // non-zero only while associated, so that still tells connected
        // from not.
        isWiFiConnected = isWiFiOn && (interface?.rssiValue() ?? 0) != 0
        wifiName = isWiFiConnected ? interface?.ssid() : nil
        if let device = Self.defaultOutputDevice() {
            volume = Self.readVolume(device) ?? 0
            isMuted = Self.readMute(device)
        }
    }

    // MARK: - Quick settings

    private(set) var brightness: Float?
    private(set) var bluetoothOn: Bool?
    private(set) var isDarkMode = false

    /// Read when the popup opens rather than on the 5 s poll: asking for the
    /// Bluetooth state can raise macOS's Bluetooth permission prompt, which
    /// shouldn't happen out of the blue.
    func refreshQuickSettings() {
        brightness = Self.readBrightness()
        bluetoothOn = Self.readBluetooth()
        isDarkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    func setBrightness(_ value: Float) {
        guard let set = Self.displayServices("DisplayServicesSetBrightness", SetBrightness.self) else { return }
        _ = set(CGMainDisplayID(), min(max(value, 0), 1))
        brightness = value
    }

    func toggleBluetooth() {
        guard let on = bluetoothOn, let set = Self.bluetooth("IOBluetoothPreferenceSetControllerPowerState", SetPower.self) else { return }
        set(on ? 0 : 1)
        bluetoothOn = !on
    }

    func toggleDarkMode() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let symbol = dlsym(handle, "SLSSetAppearanceThemeLegacy") else { return }
        unsafeBitCast(symbol, to: SetTheme.self)(!isDarkMode)
        isDarkMode.toggle()
    }

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void
    private typealias SetTheme = @convention(c) (Bool) -> Void

    private static func displayServices<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static func bluetooth<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW),
              let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// `nil` on a display that has no brightness control (an external one).
    private static func readBrightness() -> Float? {
        guard let get = displayServices("DisplayServicesGetBrightness", GetBrightness.self) else { return nil }
        var value: Float = 0
        return get(CGMainDisplayID(), &value) == 0 ? value : nil
    }

    private static func readBluetooth() -> Bool? {
        bluetooth("IOBluetoothPreferenceGetControllerPowerState", GetPower.self).map { $0() != 0 }
    }

    func setVolume(_ value: Float) {
        guard let device = Self.defaultOutputDevice() else { return }
        var level = min(max(value, 0), 1)
        var address = Self.address(Self.virtualMainVolume)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
        if level > 0, isMuted { setMuted(false) }
        volume = level
    }

    func setMuted(_ muted: Bool) {
        guard let device = Self.defaultOutputDevice() else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        isMuted = muted
    }

    // MARK: - Readers

    private static func readBattery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let remaining = description[kIOPSTimeToEmptyKey] as? Int
            return Battery(
                percent: min(100, capacity * 100 / maximum),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesRemaining: (remaining ?? -1) > 0 ? remaining : nil
            )
        }
        return nil
    }

    /// `'vmvc'` — the output device's overall volume, whatever its channel
    /// layout (AudioHardwareService's "virtual main volume").
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func readVolume(_ device: AudioDeviceID) -> Float? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = address(virtualMainVolume)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func readMute(_ device: AudioDeviceID) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyMute)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }
}
