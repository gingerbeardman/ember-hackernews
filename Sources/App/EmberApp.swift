import SwiftUI
import UIKit

/// Sets the notification-center delegate before launch finishes so a lock-screen
/// tap on a cold start is delivered instead of dropped.
final class EmberAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationService.shared.configure()
        return true
    }
}

@main
struct EmberApp: App {
    @UIApplicationDelegateAdaptor(EmberAppDelegate.self) private var appDelegate
    @State private var settings = SettingsStore()
    @State private var bookmarks = BookmarkStore()
    @State private var readStore = ReadStore()
    @State private var linkOpener = LinkOpener()
    @State private var account = AccountStore()
    @State private var voteStore = VoteStore()
    @State private var pendingComments = PendingCommentStore()
    @State private var favorites = FavoritesStore()
    @State private var savedSearches = SavedSearchStore()
    @State private var matchInbox = MatchInboxStore()
    @State private var notifications = NotificationService.shared
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(bookmarks)
                .environment(readStore)
                .environment(linkOpener)
                .environment(account)
                .environment(voteStore)
                .environment(pendingComments)
                .environment(favorites)
                .environment(savedSearches)
                .environment(matchInbox)
                .environment(notifications)
                .environment(router)
                .task {
                    notifications.configure()
                    await account.restore()
                    if let username = account.username {
                        await favorites.refresh(username: username)
                    }
                }
        }
    }
}
