import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Drag payload for reordering taskbar icons. In-process only (drag source
/// and drop target are both this app), so an ad-hoc, unregistered UTType is
/// fine — it doesn't need to be recognized system-wide.
struct TaskDragItem: Codable, Transferable {
    let bundleIdentifier: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .taskbarItem)
    }
}

extension UTType {
    static let taskbarItem = UTType(exportedAs: "dev.nikos.taskbarreplacement.taskitem")
}

private struct TaskDraggable: ViewModifier {
    let bundleIdentifier: String?

    func body(content: Content) -> some View {
        if let bundleIdentifier {
            content.draggable(TaskDragItem(bundleIdentifier: bundleIdentifier))
        } else {
            content
        }
    }
}

/// Handles everything a taskbar icon can receive as a drop target, through
/// one `DropDelegate` instead of layering SwiftUI's `.dropDestination` (for
/// reordering) and `.onDrop` (for file-drag spring loading) on the same
/// view — the two didn't coexist properly (only one actually received
/// drops), which is why file drags weren't triggering spring-loading on
/// app icons even though it worked fine on the plain-`.onDrop` minimize
/// button.
private struct TaskDropDelegate: DropDelegate {
    let bundleIdentifier: String?
    let windowManager: WindowManager
    let onSpringLoad: (() -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.taskbarItem]) || info.hasItemsConforming(to: [.fileURL])
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
        guard let bundleIdentifier, info.hasItemsConforming(to: [.taskbarItem]) else { return false }
        let providers = info.itemProviders(for: [.taskbarItem])
        guard let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(for: .taskbarItem) { data, _ in
            guard let data, let item = try? JSONDecoder().decode(TaskDragItem.self, from: data) else { return }
            DispatchQueue.main.async {
                windowManager.reorder(draggedBundleIdentifier: item.bundleIdentifier, droppedOnBundleIdentifier: bundleIdentifier)
            }
        }
        return true
    }
}

extension View {
    /// Drag-to-reorder among taskbar icons (synced with the real Dock's
    /// pinned-apps order — see `WindowManager.reorder`) and, optionally,
    /// Dock-style "spring loading": hovering a drag of files from another
    /// app over this icon for half a second runs `onSpringLoad` (typically
    /// raising the corresponding window/app, or minimizing everything for
    /// the "show desktop" button). Reordering is a no-op without a
    /// `bundleIdentifier` (e.g. a non-bundled executable) — dragging still
    /// works, spring loading just does its own thing.
    func taskReorderable(bundleIdentifier: String?, windowManager: WindowManager, onSpringLoad: (() -> Void)? = nil) -> some View {
        modifier(TaskDraggable(bundleIdentifier: bundleIdentifier))
            .onDrop(of: [.taskbarItem, .fileURL], delegate: TaskDropDelegate(bundleIdentifier: bundleIdentifier, windowManager: windowManager, onSpringLoad: onSpringLoad))
    }
}
