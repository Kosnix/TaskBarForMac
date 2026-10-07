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
                AttentionPulse(isActive: AppStatusStore.shared.attention.contains(bundleIdentifier)) { pulse in
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .wiggle(isActive: windowManager.isEditingIcons, since: windowManager.editModeChangedAt, seed: bundleIdentifier.hashValue)
                    .hoverLift(isHovered: isHovered || pulse, zoomRatio: tokens.effectiveTaskbarIconHoverZoom, isPressed: windowManager.pressedIconID == "group-\(bundleIdentifier)")
                    // A single-window app never reaches this view at all
                    // (see `WindowManager.groupedEntries`, which only groups
                    // 2+ windows), so there's always a meaningful count to
                    // show — same badge style `TaskButtonView` uses for its
                    // own single-minimized-window case.
                    .taskWindowCountBadge(.count(windows.count), accentColor: Color(hex: tokens.colors.accent))
                    .appNotificationBadge(AppStatusStore.shared.badges[bundleIdentifier])
                    .appProgressBar(AppStatusStore.shared.progress[bundleIdentifier], accentColor: Color(hex: tokens.colors.accent))
                }
            }
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
        .overlay(activeUnderline, alignment: .bottom)
        // No more `.clipShape` — see `TaskButtonView`'s identical removal.
        .contentShape(Rectangle())
        .help(windowManager.resolvedDisplayName(bundleIdentifier: realBundleIdentifier, fallback: appName))
        .contextMenu {
            if !windowManager.isEditingIcons, let pid = windows.first?.pid {
                JumpListMenu(bundleIdentifier: realBundleIdentifier, appURL: NSRunningApplication(processIdentifier: pid)?.bundleURL, pid: pid)
            }
            // Unpinning works outside edit mode too now.
            if windowManager.isPinned(bundleIdentifier: bundleIdentifier) {
                Button(L("taskbar.unpin")) {
                    windowManager.togglePin(pid: windows.first?.pid ?? 0, bundleIdentifier: bundleIdentifier, displayName: appName)
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
            if !windowManager.isEditingIcons {
                Divider()
                Button(L("window.close_all")) {
                    windowManager.closeAll(bundleIdentifier: bundleIdentifier, windows: windows)
                }
                // Only once a previous "Close All" didn't actually get rid
                // of every window after a short grace period — see
                // `WindowManager.scheduleStuckCloseCheck` — so this isn't
                // sitting there as a tempting shortcut past an app's own
                // "Save changes?" prompt on the very first try.
                if windowManager.isCloseStuck(bundleIdentifier: realBundleIdentifier, pid: windows.first?.pid ?? 0) {
                    Button(L("window.force_quit")) {
                        windowManager.forceQuit(bundleIdentifier: realBundleIdentifier, pid: windows.first?.pid ?? 0)
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
        .background(GroupFrameReporter(bundleIdentifier: bundleIdentifier, windowManager: windowManager))
        // Last: needs to sit on top of `.taskReorderable`'s own `.onDrop`
        // target to actually receive left-clicks — see
        // `IconPressGesture.swift`'s doc comment.
        .iconPressAndHold(windowManager: windowManager, bundleIdentifier: realBundleIdentifier, pressID: "group-\(bundleIdentifier)", onMiddleClick: {
            if let pid = windows.first?.pid { JumpListStore.shared.openNewWindow(pid: pid) }
        }) {
            // Primary click with no clear "the" window: raise the first
            // one, same as the ⌘⌥1…9 shortcut does for a group.
            if let first = windows.first {
                windowManager.raise(first)
            }
        } onHoverChange: { hovering in
            windowManager.setGroupHovered(bundleIdentifier, hovering: hovering)
            if hovering, let pid = windows.first?.pid {
                JumpListStore.shared.prefetch(bundleIdentifier: realBundleIdentifier, appURL: NSRunningApplication(processIdentifier: pid)?.bundleURL, pid: pid)
            }
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

private struct GroupFrameReporter: View {
    let bundleIdentifier: String
    let windowManager: WindowManager
    @Environment(\.barID) private var barID

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { windowManager.groupButtonFrames[BarFrames.key(barID, bundleIdentifier)] = geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace)) }
                .onChange(of: geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace))) { _, newValue in
                    windowManager.groupButtonFrames[BarFrames.key(barID, bundleIdentifier)] = newValue
                }
        }
    }
}
