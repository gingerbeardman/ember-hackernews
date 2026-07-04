import Foundation
import Observation

/// Persisted saved searches plus the logic that, on each feed refresh, re-runs
/// the notifying ones and fires a local notification for genuinely new matches.
/// JSON-file persistence mirrors `BookmarkStore`.
@MainActor
@Observable
final class SavedSearchStore {
    private(set) var searches: [SavedSearch] = []

    /// Max individual notifications per check before we collapse into a summary.
    private static let maxIndividualNotifications = 3

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let notifier: NotificationService
    /// Guards against overlapping checks (e.g. rapid pull-to-refresh).
    @ObservationIgnored private var isChecking = false

    init(filename: String = "saved-searches.json",
         notifier: NotificationService = .shared) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(filename)
        self.notifier = notifier
        load()
    }

    // MARK: Mutations

    /// Create a saved search, seeding its high-water mark from the current top
    /// match so the existing backlog stays silent. Returns the created search.
    @discardableResult
    func add(query: String, scope: SavedSearch.Scope, notify: Bool,
             using service: HNServicing) async -> SavedSearch {
        var search = SavedSearch(query: query, scope: scope, notify: notify)
        let hits = await matches(for: search, using: service)
        search.lastSeenMaxID = hits.compactMap(\.itemID).max() ?? 0
        searches.insert(search, at: 0)
        persist()
        if notify { await notifier.requestAuthorization() }
        return search
    }

    func remove(_ id: UUID) {
        searches.removeAll { $0.id == id }
        persist()
    }

    /// Toggle notifications for a search, requesting authorization when enabling.
    func setNotify(_ notify: Bool, for id: UUID) async {
        guard let index = searches.firstIndex(where: { $0.id == id }) else { return }
        searches[index].notify = notify
        persist()
        if notify { await notifier.requestAuthorization() }
    }

    // MARK: Checking

    /// Re-run every notifying search and notify for matches newer than each
    /// search's high-water mark. Called after a feed refresh.
    func check(using service: HNServicing) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var changed = false
        for index in searches.indices where searches[index].notify {
            let search = searches[index]
            let hits = await matches(for: search, using: service)
            let fresh = hits.filter { ($0.itemID ?? 0) > search.lastSeenMaxID }
            guard !fresh.isEmpty else { continue }

            notify(fresh, for: search)
            let highest = hits.compactMap(\.itemID).max() ?? search.lastSeenMaxID
            searches[index].lastSeenMaxID = max(search.lastSeenMaxID, highest)
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Matching

    /// Run a search and, for `.domain` scope, keep only exact-host matches.
    private func matches(for search: SavedSearch, using service: HNServicing) async -> [SearchHit] {
        let query = search.trimmedQuery
        guard query.count >= 2 else { return [] }
        let hits = (try? await service.search(
            query, mode: .recent, page: 0,
            restrictToURL: search.scope == .domain)) ?? []
        guard search.scope == .domain else { return hits }
        let host = search.normalizedHost
        return hits.filter { $0.host?.lowercased() == host }
    }

    /// Post notifications for new matches: up to a few individually, then a
    /// single summary for the remainder.
    private func notify(_ hits: [SearchHit], for search: SavedSearch) {
        let sorted = hits.sorted { ($0.itemID ?? 0) > ($1.itemID ?? 0) }
        let individual = sorted.prefix(Self.maxIndividualNotifications)
        for hit in individual {
            notifier.post(
                title: "New on Hacker News",
                body: "\(hit.title ?? "Untitled") — \(hit.host ?? search.displayLabel)",
                itemID: hit.itemID)
        }
        let overflow = sorted.count - individual.count
        if overflow > 0 {
            notifier.post(
                title: "New matches for \(search.displayLabel)",
                body: "\(overflow) more new \(overflow == 1 ? "story" : "stories") on Hacker News",
                itemID: nil)
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return }
        searches = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(searches) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
