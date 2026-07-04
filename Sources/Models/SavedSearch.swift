import Foundation

/// A search the user has saved to re-run and, optionally, be notified about when
/// new matching stories appear. A `.domain` search watches a website (e.g. a
/// personal blog); `.anywhere` is a general saved query.
struct SavedSearch: Codable, Identifiable, Hashable {
    let id: UUID
    var query: String
    var scope: Scope
    var notify: Bool
    /// High-water mark: the largest HN item id seen for this search. HN ids are
    /// monotonic, so anything greater is genuinely new. Seeded on creation so the
    /// existing backlog never fires a notification.
    var lastSeenMaxID: Int
    var createdAt: Date

    enum Scope: String, Codable, CaseIterable, Identifiable {
        case anywhere, domain
        var id: String { rawValue }
        var title: String { self == .anywhere ? "Anywhere" : "Domain" }
        var systemImage: String { self == .anywhere ? "text.magnifyingglass" : "link" }

        /// Pick a sensible scope for a query: `.domain` when it validates as a
        /// URL or bare domain (e.g. "example.com", "https://blog.example.com"),
        /// `.anywhere` otherwise (e.g. "Swift", "vision pro").
        static func inferred(from query: String) -> Scope {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, !trimmed.contains(" ") else { return .anywhere }
            // Accept full URLs as-is; treat a bare token as a host.
            let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            guard let host = URL(string: candidate)?.host(), host.contains(".") else { return .anywhere }
            // Require a plausible letters-only TLD so "1.5" isn't read as a domain.
            let tld = host.split(separator: ".").last.map(String.init) ?? ""
            return tld.count >= 2 && tld.allSatisfy(\.isLetter) ? .domain : .anywhere
        }
    }

    init(id: UUID = UUID(), query: String, scope: Scope, notify: Bool,
         lastSeenMaxID: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.query = query
        self.scope = scope
        self.notify = notify
        self.lastSeenMaxID = lastSeenMaxID
        self.createdAt = createdAt
    }
}

extension SavedSearch {
    /// The query trimmed of whitespace.
    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For `.domain` searches, the bare host to match against `SearchHit.host`.
    /// Tolerates the user typing a full URL, a `www.` prefix, or a trailing path.
    var normalizedHost: String {
        var value = trimmedQuery.lowercased()
        if let host = URL(string: value)?.host() {
            value = host
        } else if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }

    /// Human label for the scope + query, e.g. "gingerbeardman.com" or "Swift".
    var displayLabel: String {
        scope == .domain ? normalizedHost : trimmedQuery
    }
}
