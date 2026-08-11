import Foundation
import Observation

/// Direction of a user's vote on an item. HN only allows one active vote at a time.
enum VoteDirection: String, Codable {
    case up, down
}

/// Remembers which items the signed-in user has up- or down-voted, so the
/// optimistic state survives navigation and relaunch (HN's API doesn't expose it).
/// Backed by `UserDefaults`, bounded so it can't grow without limit.
@Observable
final class VoteStore {
    private(set) var upvotedIDs: Set<Int> = []
    private(set) var downvotedIDs: Set<Int> = []

    private let defaults: UserDefaults
    private let upKey = "votes.upvotedIDs"
    private let downKey = "votes.downvotedIDs"
    private let maxEntries = 5_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let array = defaults.array(forKey: upKey) as? [Int] {
            upvotedIDs = Set(array)
        }
        if let array = defaults.array(forKey: downKey) as? [Int] {
            downvotedIDs = Set(array)
        }
    }

    /// Legacy name used throughout the UI for "has an active upvote".
    func hasVoted(_ id: Int) -> Bool { hasUpvoted(id) }

    func hasUpvoted(_ id: Int) -> Bool { upvotedIDs.contains(id) }
    func hasDownvoted(_ id: Int) -> Bool { downvotedIDs.contains(id) }

    func direction(of id: Int) -> VoteDirection? {
        if upvotedIDs.contains(id) { return .up }
        if downvotedIDs.contains(id) { return .down }
        return nil
    }

    /// Net score adjustment from our optimistic vote (+1 up, −1 down, 0 none).
    func scoreDelta(for id: Int) -> Int {
        if upvotedIDs.contains(id) { return 1 }
        if downvotedIDs.contains(id) { return -1 }
        return 0
    }

    func markUpvoted(_ id: Int) {
        downvotedIDs.remove(id)
        upvotedIDs.insert(id)
        persist()
    }

    func markDownvoted(_ id: Int) {
        upvotedIDs.remove(id)
        downvotedIDs.insert(id)
        persist()
    }

    /// Clear any vote on the item (after a successful unvote, or a failed optimistic vote).
    func clearVote(_ id: Int) {
        let changed = upvotedIDs.remove(id) != nil || downvotedIDs.remove(id) != nil
        if changed { persist() }
    }

    /// Legacy helpers kept for call-site clarity during upvote-only flows.
    func markVoted(_ id: Int) { markUpvoted(id) }
    func unmarkVoted(_ id: Int) { clearVote(id) }

    func clear() {
        upvotedIDs = []
        downvotedIDs = []
        persist()
    }

    private func persist() {
        defaults.set(bounded(Array(upvotedIDs)), forKey: upKey)
        defaults.set(bounded(Array(downvotedIDs)), forKey: downKey)
        // Keep the stored sets in sync if we had to drop oldest entries.
        if upvotedIDs.count > maxEntries {
            upvotedIDs = Set(bounded(Array(upvotedIDs)))
        }
        if downvotedIDs.count > maxEntries {
            downvotedIDs = Set(bounded(Array(downvotedIDs)))
        }
    }

    private func bounded(_ array: [Int]) -> [Int] {
        guard array.count > maxEntries else { return array }
        return Array(array.sorted(by: >).prefix(maxEntries))
    }
}
