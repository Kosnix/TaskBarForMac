import AppKit
import Observation
import SwiftUI

@Observable
final class AltTabModel {
    var windows: [AppWindow] = []
    var selected = 0
    /// Set by a click on a card — the controller commits it.
    @ObservationIgnored var onPick: ((Int) -> Void)?
}

/// ⌥Tab window switcher with a thumbnail per window: hold ⌥, tap Tab to
/// step through the windows (⇧ to go back, arrows work too), release ⌥ to
/// switch, Esc to cancel. Most recently used app first.
///
/// Watches the keyboard through an active `CGEventTap` rather than an
/// `NSEvent` monitor, since the Tab press has to be swallowed — otherwise
/// the app underneath would also receive ⌥Tab. That needs the same
/// Accessibility trust the rest of the app already asks for; if macOS
/// refuses to create the tap, the switcher just stays off.
@MainActor
final class AltTabController {
    private let windowManager: WindowManager
    private let themeStore: ThemeStore
    private let model = AltTabModel()
    private var panel: NSPanel?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    /// App pids, most recently active first.
    private var recentPIDs: [pid_t] = []
    private var isShowing = false
    private var swallowTabKeyUp = false

    private static let tabKey: Int64 = 48
    private static let escapeKey: Int64 = 53
    private static let leftArrowKey: Int64 = 123
    private static let rightArrowKey: Int64 = 124
    private static let perRow = 6

    init(windowManager: WindowManager, themeStore: ThemeStore) {
        self.windowManager = windowManager
        self.themeStore = themeStore
        model.onPick = { [weak self] index in
            self?.model.selected = index
            self?.commit()
        }
    }

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<AltTabController>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { controller.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        recentPIDs = NSWorkspace.shared.frontmostApplication.map { [$0.processIdentifier] } ?? []
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.noteActivated(app.processIdentifier) }
        }
    }

    func stop() {
        cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func noteActivated(_ pid: pid_t) {
        recentPIDs.removeAll { $0 == pid }
        recentPIDs.insert(pid, at: 0)
    }

    // MARK: - Events

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if key == Self.tabKey, flags.contains(.maskAlternate), !flags.contains(.maskCommand), !flags.contains(.maskControl) {
                guard advance(reverse: flags.contains(.maskShift)) else { return Unmanaged.passUnretained(event) }
                swallowTabKeyUp = true
                return nil
            }
            guard isShowing else { return Unmanaged.passUnretained(event) }
            switch key {
            case Self.escapeKey: cancel()
            case Self.leftArrowKey: move(-1)
            case Self.rightArrowKey: move(1)
            default: break
            }
            return nil
        case .keyUp:
            if swallowTabKeyUp, event.getIntegerValueField(.keyboardEventKeycode) == Self.tabKey {
                swallowTabKeyUp = false
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            if isShowing, !event.flags.contains(.maskAlternate) { commit() }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Switching

    /// Returns false when there's nothing to switch between (the key then
    /// goes to the app as usual).
    private func advance(reverse: Bool) -> Bool {
        if isShowing {
            move(reverse ? -1 : 1)
            return true
        }
        let ordered = orderedWindows()
        guard !ordered.isEmpty else { return false }
        model.windows = ordered
        model.selected = ordered.count > 1 ? (reverse ? ordered.count - 1 : 1) : 0
        present()
        return true
    }

    private func move(_ delta: Int) {
        let count = model.windows.count
        guard count > 0 else { return }
        model.selected = (model.selected + delta + count) % count
    }

    private func commit() {
        guard isShowing else { return }
        let target = model.windows.indices.contains(model.selected) ? model.windows[model.selected] : nil
        hide()
        if let target { windowManager.raise(target) }
    }

    private func cancel() {
        guard isShowing else { return }
        hide()
    }

    /// Windows of the most recently active app first, each app's own
    /// windows in the order the system reports them.
    private func orderedWindows() -> [AppWindow] {
        func rank(_ window: AppWindow) -> Int { recentPIDs.firstIndex(of: window.pid) ?? Int.max }
        return windowManager.windows.enumerated()
            .sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: - Panel

    private func present() {
        guard let tokens = themeStore.activeTheme?.tokens else { return }
        let root = AltTabView(model: model, tokens: tokens, thumbnails: WindowThumbnailStore.shared, perRow: Self.perRow)
            .background(PanelBackground(tokens: tokens, liquidGlassEnabled: themeStore.liquidGlassEnabled, liquidGlassIntensity: themeStore.liquidGlassIntensity, showTopBorder: false))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: tokens.colors.textSecondary).opacity(0.25), lineWidth: 1))
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize

        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 3)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            self.panel = panel
            return panel
        }()
        panel.contentView = hosting
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ), display: true)
        panel.orderFrontRegardless()
        isShowing = true
        WindowThumbnailStore.shared.refresh(windowIDs: model.windows.compactMap(\.cgWindowID))
    }

    private func hide() {
        isShowing = false
        panel?.orderOut(nil)
    }
}

private struct AltTabView: View {
    let model: AltTabModel
    let tokens: ThemeTokens
    let thumbnails: WindowThumbnailStore
    let perRow: Int

    var body: some View {
        let rows = stride(from: 0, to: model.windows.count, by: perRow).map { Array(model.windows.indices[$0..<min($0 + perRow, model.windows.count)]) }
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { index in
                        card(model.windows[index], index: index)
                    }
                }
            }
        }
        .padding(16)
    }

    private func card(_ window: AppWindow, index: Int) -> some View {
        let isSelected = model.selected == index
        let image = window.cgWindowID.flatMap { thumbnails.images[$0] }
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).opacity(window.isMinimized ? 0.55 : 1)
                } else if let icon = window.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56).opacity(0.85)
                }
            }
            .frame(width: 190, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 6) {
                if let icon = window.appIcon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(window.title.isEmpty ? window.appName : window.title)
                    .font(.system(size: tokens.typography.fontSize))
                    .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: tokens.colors.accent).opacity(isSelected ? 0.3 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: tokens.colors.accent), lineWidth: isSelected ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture { model.onPick?(index) }
    }
}
