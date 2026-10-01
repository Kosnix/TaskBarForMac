import Foundation

/// One slot in the Launchpad grid: a single app, or a folder grouping
/// several. `id` is what everything else (frames, drag targets, page math)
/// identifies a slot by — an app's own `InstalledApp.id` (already handles
/// apps with no bundle identifier, falling back to their path) for `.app`,
/// a generated UUID string for `.folder` (folders have no app identity of
/// their own to reuse).
enum LaunchpadItem: Codable, Equatable, Identifiable {
    case app(id: String)
    case folder(id: String, name: String, appIDs: [String])

    var id: String {
        switch self {
        case .app(let id): return id
        case .folder(let id, _, _): return id
        }
    }
}

/// Persists the Launchpad grid's own custom order — every app's position,
/// and any folders grouping them — completely independent of the taskbar's
/// own pinned-apps order (`DockPinnedAppsStore`) or `AppDiscovery`'s plain
/// alphabetical list. Real Launchpad keeps exactly this kind of standing,
/// user-arranged layout rather than re-deriving it every time.
enum LaunchpadOrderStore {
    private static let key = "TB.launchpad.order"

    static func read() -> [LaunchpadItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([LaunchpadItem].self, from: data) else {
            return []
        }
        return items
    }

    static func write(_ items: [LaunchpadItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Reconciles the stored layout against what's actually installed right
    /// now: drops references to uninstalled apps (and any folder that's now
    /// empty because of it), then appends any newly-discovered app that
    /// isn't already sitting somewhere in the layout — alphabetically among
    /// themselves, at the very end, matching how the real thing settles a
    /// freshly-installed app into the last page rather than inserting it
    /// into the middle of an arrangement someone already made.
    static func resolve(installedApps: [InstalledApp]) -> [LaunchpadItem] {
        let installedByID = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.id, $0) })
        let installedIDs = Set(installedByID.keys)

        let reconciled: [LaunchpadItem] = read().compactMap { item in
            switch item {
            case .app(let id):
                return installedIDs.contains(id) ? item : nil
            case .folder(let id, let name, let appIDs):
                let kept = appIDs.filter { installedIDs.contains($0) }
                return kept.isEmpty ? nil : .folder(id: id, name: name, appIDs: kept)
            }
        }

        let knownIDs = Set(reconciled.flatMap { item -> [String] in
            switch item {
            case .app(let id): return [id]
            case .folder(_, _, let appIDs): return appIDs
            }
        })
        let newItems = installedApps
            .filter { !knownIDs.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { LaunchpadItem.app(id: $0.id) }

        return reconciled + newItems
    }

    // MARK: - Edits

    /// Moves `draggedID` to sit just before/after `targetID`.
    static func reordering(_ items: [LaunchpadItem], draggedID: String, targetID: String, insertBefore: Bool) -> [LaunchpadItem] {
        var items = items
        guard let fromIndex = items.firstIndex(where: { $0.id == draggedID }) else { return items }
        let dragged = items.remove(at: fromIndex)
        guard let toIndex = items.firstIndex(where: { $0.id == targetID }) else {
            items.insert(dragged, at: fromIndex)
            return items
        }
        items.insert(dragged, at: insertBefore ? toIndex : toIndex + 1)
        return items
    }

    /// Dropping one app directly onto another creates a new folder holding
    /// both; dropping an app onto an existing folder adds it there instead
    /// — real Launchpad's own two ways of ending up with a folder. Only an
    /// `.app` can be the thing being dragged (a folder isn't draggable onto
    /// something else to merge — real Launchpad doesn't support nested
    /// folders, so there's nothing sensible for that to do).
    static func merging(_ items: [LaunchpadItem], draggedID: String, targetID: String) -> [LaunchpadItem] {
        var items = items
        guard let draggedIndex = items.firstIndex(where: { $0.id == draggedID }),
              case .app(let draggedAppID) = items[draggedIndex],
              let targetIndex = items.firstIndex(where: { $0.id == targetID }) else { return items }

        switch items[targetIndex] {
        case .app(let targetAppID):
            items.remove(at: draggedIndex)
            guard let newTargetIndex = items.firstIndex(where: { $0.id == targetID }) else { return items }
            items[newTargetIndex] = .folder(id: UUID().uuidString, name: L("launchpad.new_folder"), appIDs: [targetAppID, draggedAppID])
        case .folder(let folderID, let name, let appIDs):
            guard !appIDs.contains(draggedAppID) else { return items }
            items.remove(at: draggedIndex)
            guard let newTargetIndex = items.firstIndex(where: { $0.id == folderID }) else { return items }
            items[newTargetIndex] = .folder(id: folderID, name: name, appIDs: appIDs + [draggedAppID])
        }
        return items
    }

    /// Pulls one app back out of a folder into the main grid (at the very
    /// end). A folder is never left holding just a single app — real
    /// Launchpad dissolves it the moment it would, with that one remaining
    /// app taking the folder's own slot directly (not appended elsewhere,
    /// the way the one that was actually pulled out is) — the exact same
    /// outcome removing the very last app already produced, just one app
    /// sooner.
    static func removingFromFolder(_ items: [LaunchpadItem], appID: String, folderID: String) -> [LaunchpadItem] {
        var items = items
        guard let folderIndex = items.firstIndex(where: { $0.id == folderID }),
              case .folder(let id, let name, let appIDs) = items[folderIndex] else { return items }
        let remaining = appIDs.filter { $0 != appID }
        switch remaining.count {
        case 0:
            items.remove(at: folderIndex)
        case 1:
            items[folderIndex] = .app(id: remaining[0])
        default:
            items[folderIndex] = .folder(id: id, name: name, appIDs: remaining)
        }
        items.append(.app(id: appID))
        return items
    }

    static func renaming(_ items: [LaunchpadItem], folderID: String, name: String) -> [LaunchpadItem] {
        var items = items
        guard let index = items.firstIndex(where: { $0.id == folderID }),
              case .folder(let id, _, let appIDs) = items[index] else { return items }
        items[index] = .folder(id: id, name: name, appIDs: appIDs)
        return items
    }
}
