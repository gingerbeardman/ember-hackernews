import Foundation

/// A Hacker News URL that Ember can open natively (discussion or user profile).
enum HNLink: Equatable {
    case item(id: Int)
    case user(username: String)

    /// Parse `news.ycombinator.com` item/user URLs (and common `hn.algolia.com`
    /// discussion links). Returns `nil` for unrelated hosts or unrecognized paths.
    static func parse(_ url: URL) -> HNLink? {
        guard let host = url.host()?.lowercased() else { return nil }
        let isHN = host == "news.ycombinator.com"
            || host == "www.news.ycombinator.com"
            || host == "hn.algolia.com"
            || host == "www.hn.algolia.com"
        guard isHN else { return nil }

        let path = url.path.lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        // /item?id=123  or  /?id=123 (rare)  or Algolia /?query=…&storyID=123
        if path == "/item" || path.hasSuffix("/item") {
            if let id = intQuery("id", in: items) { return .item(id: id) }
        }
        if let id = intQuery("id", in: items), path == "/" || path.isEmpty {
            return .item(id: id)
        }
        if let id = intQuery("storyid", in: items) ?? intQuery("storyID", in: items) {
            return .item(id: id)
        }

        // /user?id=dang
        if path == "/user" || path.hasSuffix("/user") {
            if let name = items?.first(where: { $0.name.lowercased() == "id" })?.value,
               !name.isEmpty {
                return .user(username: name)
            }
        }
        return nil
    }

    private static func intQuery(_ name: String, in items: [URLQueryItem]?) -> Int? {
        guard let raw = items?.first(where: { $0.name.lowercased() == name.lowercased() })?.value
        else { return nil }
        return Int(raw)
    }
}

/// Holds a story or user route awaiting navigation (deep links, in-app HN URLs).
/// Consumed by the root feed/desktop shells the same way notification taps are.
@Observable
@MainActor
final class AppRouter {
    /// Story (or discussion) id to push once the Stories tab is ready.
    var pendingStoryID: Int?
    /// Username to open on the Me / profile surface when possible.
    var pendingUsername: String?

    /// Resolve a comment id to its root story so the detail view loads the full thread.
    func openHNItem(id: Int, using service: HNServicing = LiveHNService.shared) {
        Task {
            // Await resolution first so a comment link opens the parent story,
            // not an orphaned Algolia subtree rooted at the comment.
            pendingStoryID = await Self.resolveStoryID(id, using: service)
        }
    }

    func openUser(username: String) {
        pendingUsername = username
    }

    /// Use Algolia's `story_id` on comments so deep-linking a comment opens the
    /// parent discussion rather than an orphaned subtree.
    static func resolveStoryID(_ id: Int, using service: HNServicing) async -> Int {
        guard let tree = try? await service.commentTree(for: id) else { return id }
        if tree.type == "comment" {
            return tree.storyId ?? tree.parentId ?? id
        }
        return tree.id
    }
}
