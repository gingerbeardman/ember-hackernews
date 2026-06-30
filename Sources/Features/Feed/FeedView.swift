import SwiftUI
import UIKit

/// Scroll position plus the current top content inset, observed together so the
/// nav-bar height can be derived from the inset.
private struct ScrollInfo: Equatable {
    var scrolled: CGFloat
    var insetTop: CGFloat
}

/// The primary feeds screen: a pinned feed selector over a paginated story list.
/// The Ember wordmark fades + lifts and the selector eases up as you scroll; the
/// nav bar collapses to reclaim the wordmark's space once it's gone.
struct FeedView: View {
    /// Bumped by the host when the Stories tab is re-selected while already
    /// active; we respond by scrolling to the top (and refreshing if stale).
    var reselectSignal: Int = 0

    @State private var vm = FeedViewModel()
    @State private var path = NavigationPath()
    /// Shown when we return to a stale index; tapping it reloads. We never auto-
    /// reload, so the user's scroll position is never yanked.
    @State private var showRefreshPill = false
    /// We resumed while a detail page was open; re-check staleness when the user
    /// returns to the index so the detail view is left undisturbed.
    @State private var staleCheckPending = false
    @State private var logoHidden = false
    @State private var logoOpacity: CGFloat = 1
    @State private var logoOffset: CGFloat = 0
    @State private var pickerOffset: CGFloat = 0
    /// Real nav-bar height, derived as `inset − statusBar − pickerHeight`, computed
    /// before the first scroll so the list doesn't jump on first use.
    @State private var navBar: CGFloat = 44
    @State private var pickerHeight: CGFloat = 0
    @State private var shownInsetTop: CGFloat = 0

    /// Picker rises at half the wordmark's rate → over 2× the scroll.
    private static let pickerRate: CGFloat = 0.5

    /// Status-bar inset from the key window (the nav bar isn't part of this).
    private var statusBarTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top) ?? 0
    }

    private func updateNavBar() {
        guard shownInsetTop > 0, pickerHeight > 0 else { return }
        let measured = shownInsetTop - statusBarTop - pickerHeight
        if measured > 1 { navBar = measured }
    }

    @Environment(SettingsStore.self) private var settings
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(\.scenePhase) private var scenePhase

    /// On returning to the app, offer a refresh if the index is stale. While a
    /// detail page is open we defer the check (handled when the path empties) so
    /// the detail view is left exactly as the user left it.
    private func checkStaleOnResume() {
        guard let interval = settings.feedRefreshInterval.interval,
              vm.isStale(olderThan: interval) else { return }
        if path.isEmpty {
            withAnimation(.snappy) { showRefreshPill = true }
        } else {
            staleCheckPending = true
        }
    }

    private func refreshFromPill() async {
        Haptics.tap()
        withAnimation(.snappy) { showRefreshPill = false }
        await vm.reload()
    }

    /// Reload if the index is stale (the same threshold the resume pill uses).
    private func refreshIfStale() {
        guard let interval = settings.feedRefreshInterval.interval,
              vm.isStale(olderThan: interval) else { return }
        Task { await refreshFromPill() }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Ember")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(logoHidden ? .hidden : .visible, for: .navigationBar)
                // One continuous bar: the picker's `.bar` extends up behind the
                // wordmark, so there's no second bar to fade or seam.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(settings.accent.color)
                            Text("Ember")
                                .font(.system(.headline, design: .rounded).weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .opacity(logoOpacity)
                        .offset(y: logoOffset)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel("Ember")
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    FeedChipBar(selection: vm.feed) { feed in
                        Haptics.selection()
                        Task { await vm.switchTo(feed) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pickerHeight = $0; updateNavBar() }
                    .offset(y: pickerOffset)
                }
                .navigationDestination(for: HNItem.self) { StoryDetailView(item: $0) }
                .navigationDestination(for: UserRoute.self) { UserView(username: $0.username) }
                .overlay(alignment: .bottom) { refreshPill }
        }
        .onChange(of: scenePhase) { old, new in
            if new == .active, old != .active { checkStaleOnResume() }
        }
        .onChange(of: path) { _, newPath in
            // Returned to the index after resuming inside a detail page.
            if newPath.isEmpty, staleCheckPending {
                staleCheckPending = false
                checkStaleOnResume()
            }
        }
        .task {
            await vm.startIfNeeded()
            #if DEBUG
            if LaunchArgs.autoOpenFirst, path.isEmpty, let first = vm.stories.first {
                path.append(first)
            }
            #endif
        }
    }

    /// Floating prompt offering to reload a stale index, without disturbing the
    /// user's place until they tap it.
    @ViewBuilder private var refreshPill: some View {
        if showRefreshPill {
            Button {
                Task { await refreshFromPill() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.accent.color)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, Spacing.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityHint("Reloads the story list, which is out of date")
        }
    }

    @ViewBuilder private var content: some View {
        switch vm.phase {
        case .loading where vm.stories.isEmpty:
            ScrollView { SkeletonList() }
                .background(Theme.background)
        case .failed(let message) where vm.stories.isEmpty:
            ScrollView {
                ErrorStateView(message: message) { Task { await vm.reload() } }
            }
            .background(Theme.background)
            .refreshable {
            if showRefreshPill { withAnimation(.snappy) { showRefreshPill = false } }
            await vm.reload()
        }
        default:
            storyList
        }
    }

    private var storyList: some View {
        ScrollViewReader { proxy in
        List {
            ForEach(Array(vm.stories.enumerated()), id: \.element.id) { index, story in
                ZStack {
                    // Hide the default disclosure chevron for a cleaner row.
                    NavigationLink(value: story) { EmptyView() }.opacity(0)
                    StoryRow(item: story, rank: index + 1,
                             onSelectUser: { path.append(UserRoute(username: $0)) })
                }
                .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l, bottom: 0, trailing: Spacing.l))
                .listRowSeparatorTint(Theme.separator)
                .listRowBackground(Theme.background)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        bookmarks.toggle(story)
                        Haptics.soft()
                    } label: {
                        Label(bookmarks.isBookmarked(story) ? "Unsave" : "Save",
                              systemImage: bookmarks.isBookmarked(story) ? "bookmark.slash.fill" : "bookmark.fill")
                    }
                    .tint(Theme.upvote)
                }
                .task {
                    if vm.shouldLoadMore(at: story) { await vm.loadNextPage() }
                }
            }

            if vm.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)
                .padding(.vertical, Spacing.s)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .onScrollGeometryChange(for: ScrollInfo.self) { geo in
            ScrollInfo(scrolled: geo.contentOffset.y + geo.contentInsets.top,
                       insetTop: geo.contentInsets.top)
        } action: { _, info in
            let scrolled = info.scrolled
            if !logoHidden {
                shownInsetTop = info.insetTop
                updateNavBar()
            }
            // Fade + lift the wordmark continuously; compensate for the inset jump
            // while hidden so it tracks the true visual position across the toggle.
            let visualScroll = scrolled + (logoHidden ? navBar : 0)
            let progress = max(0, min(1, visualScroll / navBar))
            logoOpacity = max(0.001, 1 - progress)
            logoOffset = -progress * navBar
            // Picker eases up at half rate; offset compensated once hidden so it
            // stays put across the (instant) collapse.
            let pickerRise = max(0, min(navBar, visualScroll * Self.pickerRate))
            pickerOffset = logoHidden ? (navBar - pickerRise) : -pickerRise
            // Collapse instantly. Un-collapse a bar-height from the top so the
            // offset never goes positive (no gap above the picker); the wide
            // hide/show gap prevents flapping.
            if !logoHidden, scrolled > navBar * 2.2 {
                logoHidden = true
            } else if logoHidden, scrolled < navBar {
                logoHidden = false
            }
        }
        .refreshable {
            if showRefreshPill { withAnimation(.snappy) { showRefreshPill = false } }
            await vm.reload()
        }
        .onChange(of: reselectSignal) { _, _ in
            if let first = vm.stories.first {
                withAnimation(.snappy) { proxy.scrollTo(first.id, anchor: .top) }
            }
            refreshIfStale()
        }
        }
    }
}

#Preview {
    FeedView()
        .environment(SettingsStore())
        .environment(BookmarkStore())
        .environment(ReadStore())
}
