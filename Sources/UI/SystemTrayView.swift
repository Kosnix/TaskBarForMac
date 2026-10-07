import SwiftUI

/// The notification area right of the clock: Wi-Fi, volume and battery
/// glyphs, refreshed every few seconds. Clicking it opens `SystemPanelView`.
struct SystemTrayView: View {
    let tokens: ThemeTokens
    let themeStore: ThemeStore

    var body: some View {
        let status = SystemStatus.shared
        return HStack(spacing: 8) {
            glyph(status.isWiFiOn ? "wifi" : "wifi.slash")
            glyph(volumeSymbol(status))
            if let battery = status.battery {
                glyph(batterySymbol(battery))
            }
        }
        .padding(.horizontal, tokens.spacing.edgePadding)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onAppear { status.startPolling() }
        .opensBarPopup("tray", themeStore: themeStore) {
            SystemPanelView(tokens: tokens, quickSettings: themeStore.quickSettingsEnabled, focusShortcutName: themeStore.focusShortcutName)
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: tokens.typography.fontSize + 1))
            .foregroundStyle(Color(hex: tokens.colors.textPrimary))
    }

    private func volumeSymbol(_ status: SystemStatus) -> String {
        if status.isMuted || status.volume == 0 { return "speaker.slash.fill" }
        if status.volume < 0.34 { return "speaker.wave.1.fill" }
        return status.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private func batterySymbol(_ battery: SystemStatus.Battery) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }
}

/// The popup the tray opens: volume slider with a mute button, Wi-Fi state
/// and battery level, each row leading to the matching System Settings pane.
struct SystemPanelView: View {
    let tokens: ThemeTokens
    var quickSettings = false
    var focusShortcutName = ""
    let status = SystemStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                row(symbol: status.isMuted || status.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", title: L("tray.volume"), detail: "\(Int((status.volume * 100).rounded())) %", pane: "com.apple.Sound-Settings.extension")
                HStack(spacing: 8) {
                    Button { status.setMuted(!status.isMuted) } label: {
                        Image(systemName: status.isMuted ? "speaker.slash" : "speaker")
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    Slider(value: Binding(get: { Double(status.volume) }, set: { status.setVolume(Float($0)) }), in: 0...1)
                }
            }
            row(symbol: status.isWiFiOn ? "wifi" : "wifi.slash", title: "Wi-Fi", detail: wifiDetail, pane: "com.apple.wifi-settings-extension")
            if let battery = status.battery {
                row(symbol: battery.isCharging ? "battery.100.bolt" : "battery.100", title: L("tray.battery"), detail: batteryDetail(battery), pane: "com.apple.Battery-Settings.extension")
            }
            if quickSettings {
                Divider()
                quickSettingsSection
            }
        }
        .padding(16)
        .frame(width: 280)
        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
        .font(.system(size: tokens.typography.fontSize))
        .onAppear {
            status.refresh()
            if quickSettings { status.refreshQuickSettings() }
        }
    }

    // MARK: - Quick settings

    private var quickSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let brightness = status.brightness {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max").frame(width: 20)
                    Slider(value: Binding(get: { Double(brightness) }, set: { status.setBrightness(Float($0)) }), in: 0...1)
                }
            }
            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                tile(symbol: status.isDarkMode ? "moon.fill" : "sun.max.fill", title: L("quick.dark_mode"), isOn: status.isDarkMode) {
                    status.toggleDarkMode()
                }
                if let bluetooth = status.bluetoothOn {
                    tile(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth", isOn: bluetooth) {
                        status.toggleBluetooth()
                    }
                }
                tile(symbol: "moon.circle.fill", title: L("quick.focus"), isOn: false, action: toggleFocus)
                tile(symbol: "airplayaudio", title: "AirDrop", isOn: false) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"))
                    BarPopups.shared.close()
                }
            }
        }
    }

    private func tile(symbol: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(Color(hex: isOn ? tokens.colors.accentText : tokens.colors.textPrimary))
            .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Color(hex: tokens.colors.accent) : Color(hex: tokens.colors.buttonBackgroundHover).opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// macOS has no way to switch Focus from outside Control Center except
    /// through a Shortcut ("Set Focus"), so this runs the one named in
    /// Settings — and opens Focus settings when there isn't one.
    private func toggleFocus() {
        let name = focusShortcutName
        guard !name.isEmpty else {
            openFocusSettings()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { DispatchQueue.main.async { openFocusSettings() } }
        }
    }

    private var wifiDetail: String {
        if !status.isWiFiOn { return L("tray.wifi_off") }
        return status.wifiName ?? (status.isWiFiConnected ? L("tray.wifi_connected") : L("tray.wifi_not_connected"))
    }

    private func batteryDetail(_ battery: SystemStatus.Battery) -> String {
        var text = "\(battery.percent) %"
        if battery.isCharging {
            text += " · " + L("tray.charging")
        } else if battery.isOnAC {
            text += " · " + L("tray.on_ac")
        } else if let minutes = battery.minutesRemaining {
            text += " · \(minutes / 60) h \(String(format: "%02d", minutes % 60))"
        }
        return text
    }

    private func row(symbol: String, title: String, detail: String, pane: String) -> some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
            BarPopups.shared.close()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.system(size: tokens.typography.fontSize - 1)).foregroundStyle(Color(hex: tokens.colors.textSecondary))
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private func openFocusSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
    BarPopups.shared.close()
}
