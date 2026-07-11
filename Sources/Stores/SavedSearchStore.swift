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
    /// Avoid unbounded API traffic for exceptionally broad or long-neglected searches.
    private static let maxSearchPagesPerCheck = 10

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
             using service: HNServicing, recordingInto inbox: MatchInboxStore) async -> SavedSearch {
        var search = SavedSearch(query: query, scope: scope, notify: notify)
        let hits = await matches(for: search, using: service, fetchUntilHighWaterMark: false)
        search.lastSeenMaxID = hits.compactMap(\.itemID).max() ?? 0
        searches.insert(search, at: 0)
        persist()
        // Surface the initial run immediately in Recent Matches, but keep the
        // high-water mark seeded so existing stories do not fire notifications.
        inbox.record(hits, for: search)
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
    /// search's high-water mark. Called after a feed refresh. New matches are
    /// also recorded into `inbox` for the in-app list and unread badge.
    func check(using service: HNServicing, recordingInto inbox: MatchInboxStore) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var changed = false
        for index in searches.indices where searches[index].notify {
            let search = searches[index]
            let hits = await matches(for: search, using: service, fetchUntilHighWaterMark: true)
            let fresh = hits.filter { ($0.itemID ?? 0) > search.lastSeenMaxID }
            guard !fresh.isEmpty else { continue }

            notify(fresh, for: search)
            inbox.record(fresh, for: search)
            let highest = hits.compactMap(\.itemID).max() ?? search.lastSeenMaxID
            searches[index].lastSeenMaxID = max(search.lastSeenMaxID, highest)
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Matching

    /// Run a search and, for `.domain` scope, keep only exact-host matches.
    private func matches(for search: SavedSearch, using service: HNServicing,
                         fetchUntilHighWaterMark: Bool) async -> [SearchHit] {
        let query = search.trimmedQuery
        guard query.count >= 2 else { return [] }
        var hits: [SearchHit] = []
        let shouldPaginate = fetchUntilHighWaterMark && search.lastSeenMaxID > 0
        for page in 0..<(shouldPaginate ? Self.maxSearchPagesPerCheck : 1) {
            guard let pageHits = try? await service.search(
                query, mode: .recent, page: page,
                restrictToURL: search.scope == .domain) else { break }
            hits.append(contentsOf: pageHits)
            // Results are newest-first. Once a page reaches an item we have
            // already considered, no following page can contain a new match.
            if pageHits.isEmpty || pageHits.contains(where: { ($0.itemID ?? 0) <= search.lastSeenMaxID }) {
                break
            }
        }
        guard search.scope == .domain else {
            // Algolia applies typo tolerance and other relevance heuristics, which
            // can return stories that do not actually contain the saved terms.
            // Saved-search notifications should be deterministic: require every
            // whitespace-delimited term in the title, URL, or story text.
            let terms = query.split(whereSeparator: \Character.isWhitespace).map {
                String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }
            return hits.filter { hit in
                let searchable = [hit.title, hit.url, hit.storyText]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return terms.allSatisfy(searchable.contains)
            }
        }
        let host = search.normalizedHost
        return hits.filter { $0.host?.lowercased() == host }
    }

    /// Post notifications for new matches: up to a few individually, then a
    /// single summary for the remainder. The saved search is the title so
    /// Notification Centre groups results by search; the body is the story.
    private func notify(_ hits: [SearchHit], for search: SavedSearch) {
        let thread = search.id.uuidString
        let sorted = hits.sorted { ($0.itemID ?? 0) > ($1.itemID ?? 0) }
        let individual = sorted.prefix(Self.maxIndividualNotifications)
        for hit in individual {
            let source = hit.host.map { " — \($0)" } ?? ""
            notifier.post(
                title: search.displayLabel,
                body: "\(hit.title ?? "Untitled")\(source)",
                itemID: hit.itemID,
                threadID: thread)
        }
        let remainder = sorted.dropFirst(individual.count)
        let overflow = remainder.count
        if overflow > 0 {
            notifier.post(
                title: search.displayLabel,
                body: "\(overflow) more new \(overflow == 1 ? "story" : "stories") on Hacker News",
                itemID: remainder.first?.itemID,
                threadID: thread)
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
