import SwiftUI
import UIKit

/// Adaptive root: a sidebar-driven split view on Mac and regular-width iPad,
/// and a tab bar on iPhone. Shared app chrome (accent, color scheme, link
/// handling, in-app browser, onboarding) is applied once here for both.
struct RootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(ReadStore.self) private var readStore
    @Environment(LinkOpener.self) private var linkOpener
    @Environment(AccountStore.self) private var account
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var systemOpenURL
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var linkOpener = linkOpener

        Group {
            if sizeClass == .compact {
                MobileRootView()
            } else {
                DesktopRootView()
            }
        }
        .tint(settings.accent.color)
        .onChange(of: settings.appearance, initial: true) { _, appearance in
            applyInterfaceStyle(appearance.uiStyle)
        }
        // Route explicit article opens through the in-app browser (or system).
        // HN item/user links open natively instead of Safari.
        .environment(\.openArticle) { url in
            if handleHNLink(url) { return }
            if settings.openLinksInApp {
                linkOpener.present(url, reader: settings.readerMode)
            } else {
                systemOpenURL(url)
            }
        }
        // Explicit "open this as a webpage" — never rewritten to a native HN screen.
        .environment(\.openWeb) { url in
            if settings.openLinksInApp {
                linkOpener.present(url, reader: false)
            } else {
                systemOpenURL(url)
            }
        }
        // Route inline comment/text links the same way, honoring reader mode.
        .environment(\.openURL, OpenURLAction { url in
            if handleHNLink(url) { return .handled }
            if settings.openLinksInApp {
                linkOpener.present(url, reader: settings.readerMode)
                return .handled
            }
            return .systemAction
        })
        // Cold-start / background open of an HN URL from another app.
        .onOpenURL { url in
            _ = handleHNLink(url)
        }
        .sheet(item: $linkOpener.presented) { presented in
            SafariView(url: presented.url, entersReaderIfAvailable: presented.reader)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            // Re-inject the Observation stores: presented views (full-screen
            // cover / sheet) don't reliably inherit `@Observable` environment
            // objects across the presentation boundary, which crashed the
            // Mac Catalyst build on first launch (issue #1).
            OnboardingView()
                .modifier(AppStoresEnvironment(settings: settings, bookmarks: bookmarks,
                                               readStore: readStore, linkOpener: linkOpener,
                                               account: account))
        }
    }

    /// Intercept `news.ycombinator.com/item?id=` (and user) links so they open
    /// as native discussions / profiles instead of Safari.
    @discardableResult
    private func handleHNLink(_ url: URL) -> Bool {
        guard let link = HNLink.parse(url) else { return false }
        switch link {
        case .item(let id):
            router.openHNItem(id: id)
        case .user(let username):
            router.openUser(username: username)
        }
        return true
    }

    /// Apply the chosen interface style to every window so System truly
    /// follows the device and a forced Light/Dark reliably reverts.
    private func applyInterfaceStyle(_ style: UIUserInterfaceStyle) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { showing in
                if !showing { settings.hasCompletedOnboarding = true }
            }
        )
    }
}

/// iPhone layout: a tab bar with an independent navigation stack per tab.
struct MobileRootView: View {
    @State private var selectedTab: Tab = .stories
    /// Bumped each time the already-active Stories tab is tapped, so FeedView
    /// can scroll to the top (and refresh if stale).
    @State private var storiesReselect = 0
    @Environment(SettingsStore.self) private var settings
    @Environment(AccountStore.self) private var account
    @Environment(NotificationService.self) private var notifications
    @Environment(MatchInboxStore.self) private var matchInbox
    @Environment(AppRouter.self) private var router

    enum Tab: Hashable { case stories, search, me, saved, settings }

    private var showMe: Bool { settings.accountFeaturesEnabled && account.isSignedIn }

    /// Re-selecting the current tab fires the setter with the same value; catch
    /// that for Stories to drive scroll-to-top. (Returning from a detail page is
    /// handled for free — the system pops the stack to root on the same tap.)
    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .stories, selectedTab == .stories { storiesReselect += 1 }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            FeedView(reselectSignal: storiesReselect)
                .tabItem { Label("Stories", systemImage: settings.storiesUsesListIcon ? "list.bullet" : "flame.fill") }
                .tag(Tab.stories)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            if showMe, let username = account.username {
                NavigationStack {
                    UserView(username: username)
                        .navigationDestination(for: HNItem.self) { StoryDetailView(item: $0) }
                        .navigationDestination(for: UserRoute.self) { UserView(username: $0.username) }
                }
                .tabItem { Label("Me", systemImage: "person.crop.circle.fill") }
                .badge(matchInbox.unreadCount)
                .tag(Tab.me)
            }
            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark.fill") }
                .tag(Tab.saved)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        // A tapped saved-search notification opens its story in the Stories tab;
        // FeedView consumes the pending id and pushes the detail view.
        .onChange(of: notifications.pendingItemID) { _, id in
            if id != nil { selectedTab = .stories }
        }
        // In-app / external HN deep links also land on Stories (or Me for users).
        .onChange(of: router.pendingStoryID) { _, id in
            if id != nil { selectedTab = .stories }
        }
        .onChange(of: router.pendingUsername) { _, name in
            guard let name else { return }
            if showMe, name.caseInsensitiveCompare(account.username ?? "") == .orderedSame {
                selectedTab = .me
            } else {
                // Push profile via the Stories stack as a UserRoute isn't tab-level.
                selectedTab = .stories
            }
            // Leave pendingUsername for FeedView to push UserView when needed.
            // If we opened Me for self, clear it — Me already shows that profile.
            if showMe, name.caseInsensitiveCompare(account.username ?? "") == .orderedSame {
                router.pendingUsername = nil
            }
        }
        .onAppear {
            #if DEBUG
            switch LaunchArgs.initialTab {
            case "search": selectedTab = .search
            case "saved": selectedTab = .saved
            case "settings": selectedTab = .settings
            default: break
            }
            #endif
        }
    }
}
