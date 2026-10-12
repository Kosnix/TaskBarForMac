import AppKit
import Observation

/// What running apps tell the system about themselves: the Dock badge text
/// (unread mail count, …) and the "please look at me" request that makes
/// the Dock icon bounce. Neither has a public API outside the app itself,
/// so this reads them from LaunchServices' per-application record (the same
/// source the `lsappinfo` tool prints) — private symbols, looked up at
/// runtime so a future macOS that drops them just makes both go quiet
/// instead of failing to launch.
@MainActor
@Observable
final class AppStatusStore {
    static let shared = AppStatusStore()

    /// Badge text by bundle identifier. Empty while badges are turned off.
    private(set) var badges: [String: String] = [:]
    /// Bundle identifiers of apps currently asking for attention.
    private(set) var attention: Set<String> = []
    /// Progress (0…1) the Dock shows on an app's icon — a download, a file
    /// copy — by bundle identifier.
    private(set) var progress: [String: Double] = [:]

    @ObservationIgnored private var timer: Timer?

    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private static let createASN: CreateASN? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW),
              let symbol = dlsym(handle, "_LSASNCreateWithPid") else { return nil }
        return unsafeBitCast(symbol, to: CreateASN.self)
    }()
    private static let copyItem: CopyItem? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW),
              let symbol = dlsym(handle, "_LSCopyApplicationInformationItem") else { return nil }
        return unsafeBitCast(symbol, to: CopyItem.self)
    }()

    func startPolling() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshProgress()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProgress() }
        }
    }

    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var progressRead = false

    /// The Dock's own Accessibility tree carries each icon's progress
    /// (`AXProgressValue`); the Dock keeps running (auto-hidden) behind the
    /// bar, so it's still there to read. Done off the main thread — it's
    /// several Accessibility calls per icon.
    private func refreshProgress() {
        guard !progressRead else { return }
        progressRead = true
        DispatchQueue.global(qos: .utility).async {
            let found = Self.readDockProgress()
            Task { @MainActor in
                self.progressRead = false
                if found != self.progress { self.progress = found }
            }
        }
    }

    private nonisolated static func readDockProgress() -> [String: Double] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &children) == .success,
              let lists = children as? [AXUIElement] else { return [:] }
        var result: [String: Double] = [:]
        for list in lists {
            var items: CFTypeRef?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items) == .success,
                  let dockItems = items as? [AXUIElement] else { continue }
            for item in dockItems {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, "AXProgressValue" as CFString, &value) == .success,
                      let number = value as? NSNumber else { continue }
                var fraction = number.doubleValue
                if fraction > 1 { fraction /= 100 }
                guard fraction > 0, fraction <= 1 else { continue }
                var url: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, "AXURL" as CFString, &url) == .success,
                      let appURL = url as? URL, let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else { continue }
                result[bundleIdentifier] = fraction
            }
        }
        return result
    }

    private func refresh() {
        guard let createASN = Self.createASN, let copyItem = Self.copyItem else { return }
        let badgesEnabled = (UserDefaults.standard.object(forKey: ThemeStore.notificationBadgesEnabledKey) as? Bool) ?? true
        var newBadges: [String: String] = [:]
        var newAttention: Set<String> = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleIdentifier = app.bundleIdentifier,
                  let asn = createASN(nil, app.processIdentifier)?.takeRetainedValue() else { continue }
            if badgesEnabled, let value = copyItem(-2, asn, "StatusLabel" as CFString)?.takeRetainedValue(),
               let label = Self.label(from: value) {
                newBadges[bundleIdentifier] = label
            }
            // An app that's already frontmost has your attention.
            if app != NSWorkspace.shared.frontmostApplication,
               let value = copyItem(-2, asn, "LSWantsAttention" as CFString)?.takeRetainedValue(),
               (value as? Bool) == true || (value as? NSNumber)?.boolValue == true {
                newAttention.insert(bundleIdentifier)
            }
        }
        if newBadges != badges { badges = newBadges }
        if newAttention != attention { attention = newAttention }
    }

    /// The record holds either the bare text or `{ "label" = "3" }`.
    private static func label(from value: CFTypeRef) -> String? {
        let text: String?
        if let string = value as? String {
            text = string
        } else if let dictionary = value as? [String: Any] {
            text = dictionary["label"] as? String
        } else {
            text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
