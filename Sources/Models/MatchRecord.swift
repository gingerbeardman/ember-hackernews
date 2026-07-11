import Foundation

/// A pending saved-search match in the in-app inbox: the story that matched and
/// which search surfaced it. Keyed by the HN item id so the same story never
/// appears twice. Reading (tapping through) or swiping removes it — the inbox
/// only ever holds matches the user hasn't dealt with yet.
struct MatchRecord: Codable, Identifiable, Hashable {
    /// HN item id — also the dedup key and (since HN ids are monotonic) the sort
    /// key for recency.
    let id: Int
    var title: String
    var host: String?
    /// Stable owner used to enforce the per-search inbox limit. Optional so
    /// inboxes written by older versions continue to decode.
    var searchID: UUID?
    /// The saved search that produced this match, e.g. "Nintendo".
    var searchLabel: String
    var date: Date
}
