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

    /// Register as the delegate and sync the current authorization status.
    /// Call once at launch.
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
        if let itemID { content.userInfo = ["itemID": itemID] }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request)
    }

    /// Set the app icon badge (used to mirror the unread saved-search matches).
    func setBadgeCount(_ count: Int) {
        center.setBadgeCount(count)
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
        guard let id = response.notification.request.content.userInfo["itemID"] as? Int else { return }
        await MainActor.run { pendingItemID = id }
    }
}
