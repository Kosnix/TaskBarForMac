import AppKit
import ApplicationServices
import Observation

/// Tracks whether this process is trusted for the Accessibility API, and can
/// prompt the user / deep-link into System Settings.
@Observable
final class PermissionsManager {
    private(set) var isTrusted: Bool = false
    private var pollTimer: Timer?

    init() {
        refresh()
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Shows the system's own "grant Accessibility access" prompt, which adds
    /// this app to System Settings > Privacy & Security > Accessibility.
    func requestAccess() {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        startPollingUntilGranted()
    }

    /// System Settings doesn't notify us when the toggle changes, so we poll
    /// briefly while the onboarding screen is up.
    private func startPollingUntilGranted() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.refresh()
            if self.isTrusted {
                timer.invalidate()
            }
        }
    }
}
