import AppKit
import SwiftUI

/// Edit mode for the bar's movable buttons (trash, notification area, media,
/// clipboard, screenshot, weather): they jiggle like the app icons and can be
/// dragged left or right to change their order — which `ThemeStore.moduleOrder`
/// remembers.
///
/// Outside edit mode the overlay doesn't exist for the mouse at all, so the
/// buttons click as usual; in edit mode it takes the clicks (a tap does
/// nothing, as for app icons) and turns a drag into a reorder.
private final class ModuleDragView: NSView {
    weak var windowManager: WindowManager?
    weak var themeStore: ThemeStore?
    var moduleID = ""

    /// Frames of this bar's buttons, frozen at `mouseDown` — the same
    /// reasoning as `PressAndHoldView.dragOriginalFrames`: hit-testing the
    /// live layout while it animates into its new order makes it thrash.
    private var frames: [String: CGRect] = [:]

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard windowManager?.isEditingIcons == true else { return nil }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return super.hitTest(point)
        default: return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let prefix = BarFrames.key((window as? TaskbarPanel)?.barID ?? "", "")
        frames = Dictionary(uniqueKeysWithValues: (windowManager?.moduleFrames ?? [:]).compactMap { key, frame in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), frame) : nil
        })
    }

    override func mouseDragged(with event: NSEvent) {
        guard let themeStore else { return }
        // Only the horizontal position matters, and it's the same in window
        // space and in the recorded SwiftUI frames.
        let x = event.locationInWindow.x
        guard let target = frames.filter({ $0.key != moduleID }).min(by: { abs($0.value.midX - x) < abs($1.value.midX - x) }) else { return }
        themeStore.moveModule(moduleID, relativeTo: target.key, before: x < target.value.midX)
    }
}

private struct ModuleDragOverlay: NSViewRepresentable {
    let moduleID: String
    let windowManager: WindowManager
    let themeStore: ThemeStore

    func makeNSView(context: Context) -> NSView { configured(ModuleDragView()) }
    func updateNSView(_ nsView: NSView, context: Context) { _ = configured(nsView as! ModuleDragView) }

    private func configured(_ view: ModuleDragView) -> ModuleDragView {
        view.moduleID = moduleID
        view.windowManager = windowManager
        view.themeStore = themeStore
        return view
    }
}

private struct ModuleFrameReporter: View {
    let moduleID: String
    let windowManager: WindowManager
    @Environment(\.barID) private var barID

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { windowManager.moduleFrames[BarFrames.key(barID, moduleID)] = geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace)) }
                .onChange(of: geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace))) { _, newValue in
                    windowManager.moduleFrames[BarFrames.key(barID, moduleID)] = newValue
                }
        }
    }
}

extension View {
    /// Makes a bar button jiggle and draggable in edit mode (see above).
    func reorderableModule(_ id: String, windowManager: WindowManager, themeStore: ThemeStore) -> some View {
        self
            .wiggle(isActive: windowManager.isEditingIcons, since: windowManager.editModeChangedAt, seed: id.hashValue)
            .background(ModuleFrameReporter(moduleID: id, windowManager: windowManager))
            .overlay(ModuleDragOverlay(moduleID: id, windowManager: windowManager, themeStore: themeStore))
    }
}
