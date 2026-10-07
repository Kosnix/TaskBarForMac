import SwiftUI

/// The small optional buttons and widgets the taskbar can show: media
/// controls, weather, clipboard history, a screenshot button. Each is a
/// plain glyph (or glyph + text) on the bar; the first three open a popup
/// above it (see `BarPopups`).

private func glyph(_ name: String, tokens: ThemeTokens) -> some View {
    Image(systemName: name)
        .font(.system(size: tokens.typography.fontSize + 3))
        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
}

// MARK: - Media

struct MediaWidget: View {
    let tokens: ThemeTokens
    let themeStore: ThemeStore

    var body: some View {
        let store = NowPlayingStore.shared
        Group {
            if let track = store.track {
                glyph(track.isPlaying ? "music.note" : "pause.fill", tokens: tokens)
                    .help("\(track.title) — \(track.artist)")
                    .opensBarPopup("media", themeStore: themeStore) { MediaPopupView(tokens: tokens) }
            } else {
                Color.clear.frame(width: 0)
            }
        }
        .onAppear { store.startPolling() }
    }
}

private struct MediaPopupView: View {
    let tokens: ThemeTokens
    let store = NowPlayingStore.shared

    var body: some View {
        VStack(spacing: 10) {
            if let track = store.track {
                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.system(size: tokens.typography.fontSize + 1, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(track.artist)
                        .font(.system(size: tokens.typography.fontSize))
                        .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                        .lineLimit(1)
                    Text(track.player.appName)
                        .font(.system(size: tokens.typography.fontSize - 2))
                        .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                }
                HStack(spacing: 22) {
                    control("backward.fill") { store.previous() }
                    control(track.isPlaying ? "pause.fill" : "play.fill", size: 22) { store.togglePlayPause() }
                    control("forward.fill") { store.next() }
                }
            } else {
                Text("—")
            }
        }
        .padding(16)
        .frame(width: 240)
        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
    }

    private func control(_ symbol: String, size: CGFloat = 16, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Weather

struct WeatherWidget: View {
    let tokens: ThemeTokens
    let themeStore: ThemeStore

    var body: some View {
        let store = WeatherStore.shared
        Group {
            if let snapshot = store.snapshot {
                HStack(spacing: 5) {
                    Image(systemName: WeatherStore.symbol(for: snapshot.code))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: tokens.typography.fontSize + 4))
                    Text("\(Int(snapshot.temperature.rounded()))°")
                        .font(.system(size: tokens.typography.fontSize, weight: .medium))
                }
                .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .help("\(snapshot.place) — \(L(WeatherStore.descriptionKey(for: snapshot.code)))")
                .opensBarPopup("weather", themeStore: themeStore) { WeatherPopupView(tokens: tokens) }
            } else {
                // Not fetched yet (or the city is wrong): a quiet placeholder
                // that still says why on hover.
                glyph(store.failed ? "cloud.slash" : "cloud", tokens: tokens)
                    .opacity(0.6)
                    .help(themeStore.weatherCity.isEmpty ? L("weather.set_city") : (store.failed ? L("weather.unavailable") : ""))
            }
        }
        .task(id: themeStore.weatherCity) { store.configure(city: themeStore.weatherCity) }
        .onAppear { store.configure(city: themeStore.weatherCity) }
    }
}

private struct WeatherPopupView: View {
    let tokens: ThemeTokens
    let store = WeatherStore.shared

    var body: some View {
        VStack(spacing: 6) {
            if let snapshot = store.snapshot {
                Text(snapshot.place).font(.system(size: tokens.typography.fontSize + 1, weight: .semibold))
                Image(systemName: WeatherStore.symbol(for: snapshot.code))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 40))
                Text("\(Int(snapshot.temperature.rounded()))\(snapshot.unit)")
                    .font(.system(size: 30, weight: .light))
                Text(L(WeatherStore.descriptionKey(for: snapshot.code)))
                    .font(.system(size: tokens.typography.fontSize))
                Text("↑ \(Int(snapshot.high.rounded()))°   ↓ \(Int(snapshot.low.rounded()))°")
                    .font(.system(size: tokens.typography.fontSize))
                    .foregroundStyle(Color(hex: tokens.colors.textSecondary))
            }
        }
        .padding(18)
        .frame(width: 200)
        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
    }
}

// MARK: - Clipboard

struct ClipboardWidget: View {
    let tokens: ThemeTokens
    let themeStore: ThemeStore

    var body: some View {
        glyph("doc.on.clipboard", tokens: tokens)
            .help(L("clipboard.title"))
            .opensBarPopup("clipboard", themeStore: themeStore) { ClipboardPopupView(tokens: tokens) }
            .onAppear { ClipboardHistory.shared.startPolling() }
    }
}

private struct ClipboardPopupView: View {
    let tokens: ThemeTokens
    let history = ClipboardHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("clipboard.title")).font(.system(size: tokens.typography.fontSize + 1, weight: .semibold))
                Spacer()
                if !history.items.isEmpty {
                    Button(L("clipboard.clear")) { history.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: tokens.typography.fontSize - 1))
                        .foregroundStyle(Color(hex: tokens.colors.accent))
                }
            }
            if history.items.isEmpty {
                Text(L("clipboard.empty"))
                    .font(.system(size: tokens.typography.fontSize))
                    .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(history.items.enumerated()), id: \.offset) { _, text in
                            Button {
                                BarPopups.shared.close()
                                history.paste(text)
                            } label: {
                                Text(text)
                                    .font(.system(size: tokens.typography.fontSize))
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: tokens.colors.buttonBackgroundHover).opacity(0.6)))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 300)
        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
    }
}

// MARK: - Screenshot

struct ScreenshotWidget: View {
    let tokens: ThemeTokens

    var body: some View {
        Button {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        } label: {
            glyph("camera.viewfinder", tokens: tokens)
        }
        .buttonStyle(.plain)
        .help(L("screenshot.help"))
    }
}
