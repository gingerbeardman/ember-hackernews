import Foundation
import Observation

/// A comment the user just posted that Algolia hasn't indexed yet. Persisted so
/// it survives navigation/relaunch, shown inline in the thread until the real
/// one appears (then dropped). Works around Algolia's few-minute indexing lag.
struct PendingComment: Codable, Identifiable, Hashable {
    let id: Int          // temporary negative id, unique per pending comment
    let storyID: Int
    let parentID: Int    // == storyID for a top-level comment
    let author: String
    let text: String     // raw source the user typed
    let createdAt: Date
}

/// An edit the user just saved that Algolia hasn't re-indexed yet, so the new
/// text can replace the stale rendered comment until the real update appears.
struct PendingEdit: Codable, Identifiable, Hashable {
    let commentID: Int
    let text: String
    let createdAt: Date
    var id: Int { commentID }
}

@Observable
final class PendingCommentStore {
    private(set) var pending: [PendingComment] = []
    private(set) var edits: [PendingEdit] = []

    private let defaults: UserDefaults
    private let key = "pending.comments"
    private let editsKey = "pending.edits"
    /// Give up showing a pending change after this long (assume it landed or failed).
    private let maxAge: TimeInterval = 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PendingComment].self, from: data) {
            pending = decoded.filter { Date().timeIntervalSince($0.createdAt) < maxAge }
        }
        if let data = defaults.data(forKey: editsKey),
           let decoded = try? JSONDecoder().decode([PendingEdit].self, from: data) {
            edits = decoded.filter { Date().timeIntervalSince($0.createdAt) < maxAge }
        }
    }

    func add(storyID: Int, parentID: Int, author: String, text: String) {
        let id = (pending.map(\.id).min() ?? 0) - 1 // unique decreasing negative id
        pending.append(PendingComment(id: id, storyID: storyID, parentID: parentID,
                                      author: author, text: text, createdAt: Date()))
        persist()
    }

    func addEdit(commentID: Int, text: String) {
        edits.removeAll { $0.commentID == commentID }
        edits.append(PendingEdit(commentID: commentID, text: text, createdAt: Date()))
        persist()
    }

    func forStory(_ storyID: Int) -> [PendingComment] {
        pending.filter { $0.storyID == storyID }
    }

    func edit(for commentID: Int) -> PendingEdit? {
        edits.first { $0.commentID == commentID }
    }

    /// Drop pending comments for this story whose text now appears for real, or
    /// that have aged out.
    func reconcile(storyID: Int, against realTexts: [(author: String, body: String)]) {
        let reals: [(author: String, body: String)] = realTexts.map {
            (author: $0.author.lowercased(), body: Self.normalizedBody($0.body))
        }
        pending.removeAll { p in
            guard p.storyID == storyID else { return false }
            if Date().timeIntervalSince(p.createdAt) >= maxAge { return true }
            let author = p.author.lowercased()
            let body = Self.normalizedBody(p.text)
            return reals.contains { $0.author == author && Self.bodiesMatch(body, $0.body) }
        }
        persist()
    }

    /// Drop pending edits whose new text now appears in the real comment, or that
    /// have aged out. `realByID` maps comment id → its current rendered html.
    func reconcileEdits(against realByID: [Int: String]) {
        edits.removeAll { e in
            if Date().timeIntervalSince(e.createdAt) >= maxAge { return true }
            guard let body = realByID[e.commentID] else { return false } // not in view; keep
            return Self.bodiesMatch(Self.normalizedBody(body), Self.normalizedBody(e.text))
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: key)
        }
        if let data = try? JSONEncoder().encode(edits) {
            defaults.set(data, forKey: editsKey)
        }
    }

    /// Loose identity for a comment: author + a normalised prefix of its text,
    /// so HN's rendered HTML can be matched against the raw source we posted.
    static func matchKey(author: String, body: String) -> String {
        author.lowercased() + "|" + String(normalizedBody(body).prefix(60))
    }

    /// Decode entities, strip tags, keep letters/digits only so HTML from Algolia
    /// and the plain text we stored for the phantom comment land on the same key.
    static func normalizedBody(_ body: String) -> String {
        let decoded = HTMLRenderer.decodeEntities(body)
        let stripped = decoded.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return stripped.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Exact match, or one body contains the other (HN may rewrite URLs / wrap
    /// text so the rendered form is a superset of what the user typed).
    static func bodiesMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        // Require a meaningful prefix so short comments don't false-match.
        let minLen = 16
        guard a.count >= minLen || b.count >= minLen else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a) || a.contains(b) || b.contains(a)
    }
}
