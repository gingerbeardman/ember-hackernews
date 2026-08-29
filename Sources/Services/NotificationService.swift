import Foundation
import Observation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for local notifications about
/// saved-search matches. Also acts as the notification-center delegate so
/// matches surface as banners while the app is foregrounded (checks run during a
/// feed refresh, i.e. while the app is open) and taps route to the story.
@Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Item id from a tapped notification, awaiting routing by the UI. Cleared by
    /// the consumer once handled.
    var pendingItemID: Int?
    /// Latest known authorization status, for the saved-searches UI.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    private static let itemIDKey = "itemID"

    /// Register as the delegate and sync the current authorization status.
    /// Must run in `application(_:willFinishLaunchingWithOptions:)` so a
    /// lock-screen tap on a cold launch is delivered to `didReceive`.
    func configure() {
        center.delegate = self
        Task { await refreshStatus() }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        return granted
    }

    func refreshStatus() async {
        let status = await center.notificationSettings().authorizationStatus
        await MainActor.run { authorizationStatus = status }
    }

    /// Post a local notification immediately (no trigger). `threadID` groups
    /// notifications in Notification Centre (iOS groups by thread identifier, not
    /// by title), so all matches for one saved search stack together.
    func post(title: String, body: String, itemID: Int?, threadID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let threadID { content.threadIdentifier = threadID }
        if let itemID {
            // NSNumber survives the plist round-trip the system uses when the
            // app is launched from a lock-screen tap; a raw Int often doesn't.
            content.userInfo = [Self.itemIDKey: NSNumber(value: itemID)]
            content.targetContentIdentifier = Self.requestID(for: itemID)
        }
        let identifier = itemID.map(Self.requestID(for:)) ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier,
                                            content: content, trigger: nil)
        center.add(request)
    }

    /// Drop the delivered system notification for a story the user has opened.
    func removeDelivered(itemIDs: [Int]) {
        guard !itemIDs.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: itemIDs.map(Self.requestID(for:)))
    }

    /// Set the app icon badge (used to mirror the unread saved-search matches).
    func setBadgeCount(_ count: Int) {
        center.setBadgeCount(count)
    }

    /// Stable request id so opening a story can dismiss its lock-screen banner.
    static func requestID(for itemID: Int) -> String { "match-\(itemID)" }

    /// `userInfo["itemID"]` comes back as `NSNumber` after the system
    /// serializes the payload; accept Int / NSNumber / String so a lock-screen
    /// tap still routes.
    static func itemID(from userInfo: [AnyHashable: Any]) -> Int? {
        let raw = userInfo[itemIDKey]
        if let n = raw as? NSNumber { return n.intValue }
        if let id = raw as? Int { return id }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show matches as a banner even while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Route a tapped notification to its story.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { handle(response) }
    }

    /// Pull the story id out of a notification response and queue it for the UI.
    /// Safe to call from either the notification delegate or a scene-connect path.
    @MainActor
    func handle(_ response: UNNotificationResponse) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        guard let id = Self.itemID(from: response.notification.request.content.userInfo) else { return }
        pendingItemID = id
    }
}
