import SwiftUI

@main
struct EmberApp: App {
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
