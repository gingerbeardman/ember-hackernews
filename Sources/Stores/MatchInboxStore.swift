import Foundation
import Observation

/// In-app inbox of pending saved-search matches. Feeds the unread badge shown on
/// the Me tab, the bell icon, and the app icon, and backs the "Recent Matches"
/// list in the Saved Searches screen. Reading or dismissing a match removes it.
/// JSON-file persistence mirrors `SavedSearchStore`.
@MainActor
@Observable
final class MatchInboxStore {
    private(set) var matches: [MatchRecord] = []

    /// Safety cap on stored matches; older ones fall off if the user never
    /// clears them.
    private static let maxStored = 40

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let notifier: NotificationService

    /// Pending matches — the badge value. (Everything in the inbox is unread;
    /// reading or dismissing removes it.)
    var unreadCount: Int { matches.count }

    init(filename: String = "match-inbox.json",
         notifier: NotificationService = .shared) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(filename)
        self.notifier = notifier
        load()
        syncBadge()
    }

    // MARK: Mutations

    /// Record new matches for a search, newest first, deduped by id.
    func record(_ hits: [SearchHit], for search: SavedSearch, at date: Date = Date()) {
        var byID = Dictionary(matches.map { ($0.id, $0) }) { first, _ in first }
        for hit in hits {
            guard let id = hit.itemID else { continue }
            // Don't resurface a match already pending under another search.
            guard byID[id] == nil else { continue }
            byID[id] = MatchRecord(
                id: id, title: hit.title ?? "Untitled", host: hit.host,
                searchLabel: search.displayLabel, date: date)
        }
        matches = byID.values.sorted { $0.id > $1.id }
        if matches.count > Self.maxStored { matches.removeLast(matches.count - Self.maxStored) }
        persist()
        syncBadge()
    }

    /// Remove a match once it's been read or dismissed, dropping the badge.
    func remove(_ id: Int) {
        guard let index = matches.firstIndex(where: { $0.id == id }) else { return }
        matches.remove(at: index)
        persist()
        syncBadge()
    }

    // MARK: Badge

    /// Mirror the unread count onto the app icon.
    private func syncBadge() {
        notifier.setBadgeCount(unreadCount)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MatchRecord].self, from: data) else { return }
        matches = decoded.sorted { $0.id > $1.id }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(matches) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
