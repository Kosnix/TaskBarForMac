import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dock-style "spring loading": hovering a drag of files from another app
/// over a taskbar icon for half a second runs `onSpringLoad` (typically
/// raising the corresponding window/app, or minimizing everything for the
/// "show desktop" button). Dropping an actual `.app` bundle instead pins it
/// — the same as dragging it onto the real Dock does.
///
/// Icon-to-icon reordering doesn't go through here — see
/// `IconPressGesture.swift`'s `PressAndHoldView`, which does that directly
/// (comparing the live drag point against `WindowManager.iconFrames`)
/// instead of SwiftUI's `.draggable`/`.onDrop`: the two systems were
/// fighting over the same mouse-down/mouse-up sequence, which is what kept
/// reordering from ever actually working once this app also needed its own
/// raw tap/long-press detector for reliability.
private struct SpringLoadDropDelegate: DropDelegate {
    let windowManager: WindowManager
    let onSpringLoad: (() -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard let onSpringLoad, info.hasItemsConforming(to: [.fileURL]) else { return }
        windowManager.handleExternalDragHover(isTargeted: true, action: onSpringLoad)
    }

    func dropExited(info: DropInfo) {
        guard let onSpringLoad else { return }
        windowManager.handleExternalDragHover(isTargeted: false, action: onSpringLoad)
    }

    func performDrop(info: DropInfo) -> Bool {
        pinDroppedApplications(info.itemProviders(for: [.fileURL]), windowManager: windowManager)
    }
}

/// Resolves each provider's file URL (async — `NSItemProvider` never hands
/// one over synchronously) and pins whichever ones are `.app` bundles.
/// Returns whether any provider was even worth trying, not whether a pin
/// actually happened yet — matching how `DropDelegate.performDrop`/`onDrop`
/// are meant to be used (return `true` to claim the drop before the async
/// work resolves).
@discardableResult
private func pinDroppedApplications(_ providers: [NSItemProvider], windowManager: WindowManager) -> Bool {
    guard !providers.isEmpty else { return false }
    for provider in providers {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension == "app" else { return }
            DispatchQueue.main.async {
                let displayName = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                windowManager.pin(url: url, displayName: displayName)
            }
        }
    }
    return true
}

/// Resolves each provider's file URL and moves it to the Trash — the real
/// Dock's own trash-icon behavior, which this button's icon otherwise just
/// implies without actually doing.
@discardableResult
private func trashDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
    guard !providers.isEmpty else { return false }
    for provider in providers {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                // `NSWorkspace.recycle`, not `FileManager.trashItem` — same
                // reasoning as `AppDiscovery.uninstall`'s own doc comment:
                // it goes through the Finder/Workspace services, so it can
                // prompt for authentication when the dropped file actually
                // needs it, instead of just failing outright.
                NSWorkspace.shared.recycle([url])
                // The exact sound the real Dock's own trash icon plays for
                // this same drag-and-drop gesture, not a generic system
                // sound — it ships as a plain AIFF at a fixed path, so
                // there's no need to reproduce it, just play it.
                NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif", byReference: true)?.play()
            }
        }
    }
    return true
}

extension View {
    /// Dock-style "spring loading" + drop-to-pin for file drags from other
    /// apps — see `SpringLoadDropDelegate`. `bundleIdentifier` is unused
    /// now (kept so call sites don't need to change); icon-to-icon
    /// reordering lives in `IconPressGesture.swift` instead.
    func taskReorderable(bundleIdentifier: String?, windowManager: WindowManager, onSpringLoad: (() -> Void)? = nil) -> some View {
        onDrop(of: [.fileURL], delegate: SpringLoadDropDelegate(windowManager: windowManager, onSpringLoad: onSpringLoad))
    }

    /// Dropping an app from Finder onto empty taskbar background pins it,
    /// the same as `taskReorderable` already does when the drop lands
    /// directly on an existing icon instead.
    func pinsDroppedApplications(windowManager: WindowManager) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            pinDroppedApplications(providers, windowManager: windowManager)
        }
    }

    /// Dropping any file directly onto the trash button moves it to the
    /// Trash, the same as dropping it on the real Dock's trash icon would.
    func trashesDroppedFiles() -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            trashDroppedFiles(providers)
        }
    }
}
