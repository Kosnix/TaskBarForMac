import SwiftUI

/// An app with 2+ open windows: one icon in the bar, hovering shows a
/// clickable list of its windows (title + minimize/close) above the icon —
/// not full thumbnail previews (explicitly out of scope), just a list.
struct GroupedTaskButtonView: View {
    let bundleIdentifier: String
    let appName: String
    let appIcon: NSImage?
    let windows: [AppWindow]
    let tokens: ThemeTokens
    let windowManager: WindowManager
    let width: CGFloat

    private var iconSize: CGFloat { tokens.taskbarIconSize }
    private var isHovered: Bool { windowManager.hoveredGroupID == bundleIdentifier }
    private var anyActive: Bool { windows.contains { !$0.isMinimized } }
    /// `bundleIdentifier` falls back to a synthetic "pid-…" key when a
    /// window's real app has no bundle id — not something the Dock can pin,
    /// so dragging is only offered for a real one.
    private var realBundleIdentifier: String? { bundleIdentifier.hasPrefix("pid-") ? nil : bundleIdentifier }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = windowManager.resolvedIcon(bundleIdentifier: realBundleIdentifier, fallback: appIcon) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .wiggle(isActive: windowManager.isEditingIcons, seed: bundleIdentifier.hashValue)
                    .hoverLift(isHovered: isHovered, zoomRatio: tokens.effectiveTaskbarIconHoverZoom)
            }
            windowCountBadge
        }
        .padding(.horizontal, tokens.effectiveTaskbarEdgePadding)
        // Left-aligned, not the default center: when this button's
        // allocated `width` is wider than its actual content (few open
        // windows sharing a lot of available space), centering left a gap
        // of empty space *before* the icon too, not just after it —
        // exactly the kind of "space that's still there" no amount of
        // fixing the start button's own padding could touch, since it was
        // never the start button's gap to begin with.
        .frame(width: width, height: tokens.panel.height - 8, alignment: .leading)
        // Positioned by hand, pinned to the button's own bottom edge — see
        // `TaskButtonView`'s identical overlay for why a plain `.overlay`
        // on the icon isn't enough (the icon can float vertically centered
        // within a taller button, carrying a naively-attached dot away
        // from the true bottom edge with it).
        .overlay(alignment: .bottomLeading) {
            allMinimizedDot
                .offset(x: tokens.effectiveTaskbarEdgePadding + iconSize / 2 - Self.minimizedDotSize / 2, y: -Self.minimizedDotBottomInset)
        }
        .overlay(activeUnderline, alignment: .bottom)
        // No more `.clipShape` — see `TaskButtonView`'s identical removal.
        .contentShape(Rectangle())
        .help(appName)
        .contextMenu {
            // Unpinning specifically is edit-mode-only (see `TaskButtonView`).
            if windowManager.isPinned(bundleIdentifier: bundleIdentifier) {
                if windowManager.isEditingIcons {
                    Button(L("taskbar.unpin")) {
                        windowManager.togglePin(pid: windows.first?.pid ?? 0, bundleIdentifier: bundleIdentifier, displayName: appName)
                    }
                }
            } else {
                Button(L("taskbar.pin")) {
                    windowManager.togglePin(pid: windows.first?.pid ?? 0, bundleIdentifier: bundleIdentifier, displayName: appName)
                }
            }
            if windowManager.isEditingIcons {
                Button(L("icon_edit.change")) {
                    windowManager.presentIconPicker(for: realBundleIdentifier)
                }
                if windowManager.hasCustomIcon(bundleIdentifier: realBundleIdentifier) {
                    Button(L("icon_edit.restore_original")) {
                        windowManager.restoreOriginalIcon(for: realBundleIdentifier)
                    }
                }
            }
        }
        .taskReorderable(bundleIdentifier: realBundleIdentifier, windowManager: windowManager) {
            if let first = windows.first {
                windowManager.raise(first)
            }
        }
        // Publishes this button's own frame so `TaskbarView` can position
        // the hover window-list popup itself — see `groupButtonFrames`'s
        // doc comment for why this replaced a plain SwiftUI `.popover`
        // here (same underlying issue `StartMenuState` already documents
        // for `.popover` in this app's kind of panel).
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { windowManager.groupButtonFrames[bundleIdentifier] = geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace)) }
                    .onChange(of: geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace))) { _, newValue in
                        windowManager.groupButtonFrames[bundleIdentifier] = newValue
                    }
            }
        )
        // Last: needs to sit on top of `.taskReorderable`'s own `.onDrop`
        // target to actually receive left-clicks — see
        // `IconPressGesture.swift`'s doc comment.
        .iconPressAndHold(windowManager: windowManager, bundleIdentifier: realBundleIdentifier) {
            // Primary click with no clear "the" window: raise the first
            // one, same as the ⌘⌥1…9 shortcut does for a group.
            if let first = windows.first {
                windowManager.raise(first)
            }
        } onHoverChange: { hovering in
            windowManager.setGroupHovered(bundleIdentifier, hovering: hovering)
        }
    }

    private var windowCountBadge: some View {
        Text("\(windows.count)")
            .font(.system(size: tokens.typography.fontSize - 2, weight: .semibold))
            .foregroundStyle(Color(hex: tokens.colors.textSecondary))
    }

    /// Same 0.3 Breeze `Metrics::Blend_Value` hover alpha used by
    /// `TaskButtonView` — see that file for the source reference.
    // Neither an active group nor hover get a flat background tint any
    // more — matching `TaskButtonView`.

    private static let minimizedDotSize: CGFloat = 4
    private static let minimizedDotBottomInset: CGFloat = 2

    @ViewBuilder
    private var allMinimizedDot: some View {
        if !anyActive {
            // Every window in the group is minimized — same dot convention
            // as a single minimized window (see `TaskButtonView`), instead
            // of dimming the whole button.
            Circle()
                .fill(Color(hex: tokens.colors.textSecondary))
                .frame(width: Self.minimizedDotSize, height: Self.minimizedDotSize)
        }
    }

    @ViewBuilder
    private var activeUnderline: some View {
        if anyActive && tokens.taskButton.indicatorStyle == "underline" {
            Rectangle()
                .fill(Color(hex: tokens.colors.accent))
                .frame(height: 2)
        }
    }
}
