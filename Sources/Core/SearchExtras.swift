import AppKit
import Observation

/// Spotlight-backed file lookups for the start menus: files whose name
/// matches what's typed, and the files used most recently (the "Recommended"
/// section). One-shot queries — each run gathers, takes the first few
/// results and stops, rather than staying live.
@MainActor
@Observable
final class FileSearch: NSObject {
    struct Result: Identifiable {
        let url: URL
        let lastUsed: Date?
        var id: String { url.path }
    }

    /// The "Recommended" strip's list, shared so it survives the view
    /// being rebuilt.
    static let recents = FileSearch(limit: 6)

    private(set) var results: [Result] = []

    @ObservationIgnored private let query = NSMetadataQuery()
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var debounce: DispatchWorkItem?

    init(limit: Int) {
        self.limit = limit
        super.init()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(finished), name: .NSMetadataQueryDidFinishGathering, object: query)
    }

    /// Files whose name contains `text`, most recently used first. Waits a
    /// beat so typing doesn't launch a query per keystroke.
    func search(name text: String) {
        debounce?.cancel()
        guard !text.isEmpty else {
            query.stop()
            results = []
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.run(NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemDisplayNameKey, text))
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Files used in the last two weeks, most recent first.
    func loadRecents() {
        let since = Date().addingTimeInterval(-14 * 24 * 3600) as NSDate
        run(NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, since))
    }

    /// The most recently used files of the given types (UTIs) — what the
    /// taskbar's jump list offers for an app that opens them.
    func loadRecents(contentTypes: [String]) {
        let types = NSCompoundPredicate(orPredicateWithSubpredicates: contentTypes.map {
            NSPredicate(format: "%K == %@", NSMetadataItemContentTypeTreeKey, $0)
        })
        let used = NSPredicate(format: "%K > %@", NSMetadataItemLastUsedDateKey, Date.distantPast as NSDate)
        run(NSCompoundPredicate(andPredicateWithSubpredicates: [types, used]))
    }

    private func run(_ predicate: NSPredicate) {
        query.stop()
        query.predicate = predicate
        query.start()
    }

    @objc private func finished(_ notification: Notification) {
        query.disableUpdates()
        var found: [Result] = []
        for index in 0..<min(query.resultCount, 400) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  Self.isUserFile(path: path, contentTypes: item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []) else { continue }
            found.append(Result(url: URL(fileURLWithPath: path), lastUsed: item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date))
            if found.count == limit { break }
        }
        query.stop()
        results = found
    }

    /// Documents and media — not folders, apps, hidden files or anything
    /// under a Library folder (caches, app support…).
    private static func isUserFile(path: String, contentTypes: [String]) -> Bool {
        if path.contains("/Library/") || path.contains("/.") { return false }
        return !contentTypes.contains("public.folder") && !contentTypes.contains("com.apple.application-bundle")
    }
}

/// What the start menus add under the app matches while searching: the
/// answer to a calculation, files with a matching name, and a web search.
@MainActor
@Observable
final class SearchExtras {
    static let shared = SearchExtras()

    private(set) var calculation: String?
    let files = FileSearch(limit: 5)

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        calculation = Calculator.evaluate(trimmed).map { Calculator.format($0, locale: Localization.effectiveLocale) }
        files.search(name: trimmed)
    }

    /// Return with no app matching: the answer to a calculation is copied,
    /// else the first matching file opens, else the text is searched on the web.
    static func runPrimary(query: String, onDone: () -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let extras = shared
        if extras.calculation != nil {
            extras.copyCalculation()
        } else if let file = extras.files.results.first {
            NSWorkspace.shared.open(file.url)
        } else {
            searchWeb(trimmed)
        }
        onDone()
    }

    func copyCalculation() {
        guard let calculation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(calculation, forType: .string)
    }

    static func searchWeb(_ query: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }
}
