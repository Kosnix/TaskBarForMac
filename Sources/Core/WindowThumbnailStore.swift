import AppKit
import Observation
import ScreenCaptureKit

/// Live thumbnails of windows for the taskbar's hover previews (and the
/// Alt-Tab switcher), taken with ScreenCaptureKit — which needs the Screen
/// Recording permission. Everything degrades quietly without it: callers
/// just find no image and draw the app icon instead.
@MainActor
@Observable
final class WindowThumbnailStore {
    static let shared = WindowThumbnailStore()

    private(set) var images: [CGWindowID: NSImage] = [:]
    @ObservationIgnored private var isRefreshing = false

    private static let askedKey = "TB.screenRecording.asked"
    private static let maxPixelWidth: CGFloat = 520

    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system's Screen Recording prompt, once per install — asking
    /// again on every launch for someone who said no would just be nagging.
    func requestAccessIfNeeded() {
        guard !isAuthorized, !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        CGRequestScreenCaptureAccess()
    }

    /// Captures a fresh image of each window and publishes it in `images`.
    /// A call while the previous one is still running is dropped (the
    /// caller polls anyway), so slow captures never pile up.
    func refresh(windowIDs: [CGWindowID]) {
        guard isAuthorized, !isRefreshing, !windowIDs.isEmpty else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            for id in windowIDs {
                guard let window = content.windows.first(where: { $0.windowID == id }),
                      window.frame.width > 1, window.frame.height > 1 else { continue }
                let configuration = SCStreamConfiguration()
                let scale = min(2, Self.maxPixelWidth / window.frame.width)
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.showsCursor = false
                configuration.captureResolution = .nominal
                let filter = SCContentFilter(desktopIndependentWindow: window)
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                    images[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                }
            }
        }
    }
}

extension AppWindow {
    /// The window server's id, when `WindowManager` could resolve one.
    var cgWindowID: CGWindowID? {
        id.hasPrefix("cg-") ? CGWindowID(id.dropFirst(3)) : nil
    }
}
