import SwiftUI

/// Full story view: a rich header (title, article link, self-text, meta, author)
/// over a threaded, collapsible comment list.
struct StoryDetailView: View {
    let item: HNItem
    @State private var vm: StoryDetailViewModel

    @Environment(SettingsStore.self) private var settings
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(ReadStore.self) private var readStore
    @Environment(AccountStore.self) private var account
    @Environment(VoteStore.self) private var voteStore
    @Environment(PendingCommentStore.self) private var pendingComments
    @Environment(FavoritesStore.self) private var favorites
    @Environment(\.openArticle) private var openArticle
    @Environment(\.openURL) private var openURL

    init(item: HNItem) {
        self.item = item
        _vm = State(initialValue: StoryDetailViewModel(item: item))
    }

    private var story: HNItem { vm.resolvedItem }

    @State private var pinchBaseline: Double?
    /// The comment briefly tinted after a quote jump, so the destination is clear.
    @State private var highlightedComment: Int?
    @State private var webTask: HNWebTask?
    @State private var composeTarget: ComposeTarget?
    @State private var editError: String?
    private var textScale: CGFloat { CGFloat(settings.readingTextScale) }

    /// Whether logged-in write actions (vote / reply / comment) are available.
    private var canInteract: Bool { settings.accountFeaturesEnabled && account.isSignedIn }
    /// Whether `author`'s item can be upvoted. You can't vote on your own posts —
    /// HN renders no arrow, so we hide the affordance instead of failing into web.
    private func canVote(_ author: String) -> Bool {
        canInteract && author != account.username
    }
    /// The author whose top-level threads should float to the top, if enabled.
    private var floatAuthor: String? {
        (canInteract && settings.myCommentsFirst) ? account.username : nil
    }
    private var writer: HNWebWriter { HNWebWriter(dataStore: account.dataStore) }

    /// When signed in, the save action manages HN favorites; otherwise local bookmarks.
    private var usesFavorites: Bool { settings.accountFeaturesEnabled && account.isSignedIn }
    private var isSaved: Bool {
        usesFavorites ? favorites.isFavorite(story.id) : bookmarks.isBookmarked(story)
    }
    private func toggleSaved() {
        if usesFavorites {
            Task { await favorites.toggle(story.id, writer: writer) }
        } else {
            _ = bookmarks.toggle(story)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                commentsSection(proxy: proxy)
            }
            // Keep a comfortable reading measure on wide (desktop) windows.
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .refreshable { await vm.load() }
        .navigationTitle(story.host ?? "Discussion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // Pinch anywhere in the discussion to scale reading text, like the web.
        .gesture(pinchToZoom)
        .task {
            if settings.markReadOnOpen { readStore.markRead(item.id) }
            vm.floatAuthor = floatAuthor
            vm.sort = settings.commentSort
            vm.pendingStore = pendingComments
            await vm.load()
        }
        .onChange(of: floatAuthor) { _, newValue in vm.floatAuthor = newValue }
        .onChange(of: settings.commentSort) { _, newValue in vm.sort = newValue }
        .sheet(item: $webTask) { task in
            HNWebSheet(task: task) { Task { await vm.load() } }
        }
        .sheet(item: $composeTarget) { target in
            CommentComposer(target: target) { text in
                let poster = HNWebWriter(dataStore: account.dataStore)
                switch target.kind {
                case .comment(let parentID):
                    try await poster.post(parentID: parentID, storyID: target.storyID, text: text)
                case .edit(let commentID):
                    try await poster.editComment(commentID: commentID, text: text)
                }
            } onPosted: { text in
                // Algolia lags by minutes, so reflect the change immediately and
                // let a later refresh reconcile it.
                switch target.kind {
                case .comment(let parentID):
                    pendingComments.add(storyID: story.id, parentID: parentID,
                                        author: account.username ?? "you", text: text)
                case .edit(let commentID):
                    pendingComments.addEdit(commentID: commentID, text: text)
                }
                Task { await vm.load() }
            }
        }
        .alert("Couldn't edit", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editError ?? "")
        }
        }
    }

    /// Jump to the comment a tapped quote came from, tinting it briefly so the
    /// destination is obvious. A firmer haptic when the source can't be resolved.
    private func performQuoteJump(from id: Int, quote: String, proxy: ScrollViewProxy) {
        guard let target = vm.quoteTarget(from: id, quote: quote) else {
            Haptics.rigid()
            return
        }
        Haptics.soft()
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .top)
            highlightedComment = target
        }
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.easeOut(duration: 0.4)) { highlightedComment = nil }
        }
    }

    /// Scroll to the next comment at `level`, or a firmer bump at the last one.
    private func performSkip(from id: Int, level: Int, proxy: ScrollViewProxy) {
        if let target = vm.skipTarget(from: id, level: level) {
            Haptics.soft()
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .top)
            }
        } else {
            Haptics.rigid()
        }
    }

    // MARK: Write actions

    /// Toggle an upvote: first tap upvotes, second unvotes. Optimistic; falls back to web.
    private func toggleUpvote(_ id: Int) {
        guard canInteract else { return }
        if voteStore.hasUpvoted(id) {
            applyVote(id, action: .unvote, optimistic: { voteStore.clearVote(id) })
        } else {
            let previous = voteStore.direction(of: id)
            applyVote(id, action: .up, optimistic: { voteStore.markUpvoted(id) }, revert: {
                restoreVote(id, previous)
            })
        }
    }

    /// Toggle a downvote (requires HN karma). Optimistic; falls back to web on rejection.
    private func toggleDownvote(_ id: Int) {
        guard canInteract else { return }
        if voteStore.hasDownvoted(id) {
            applyVote(id, action: .unvote, optimistic: { voteStore.clearVote(id) })
        } else {
            let previous = voteStore.direction(of: id)
            applyVote(id, action: .down, optimistic: { voteStore.markDownvoted(id) }, revert: {
                restoreVote(id, previous)
            })
        }
    }

    private func applyVote(_ id: Int, action: HNWebWriter.VoteAction,
                           optimistic: () -> Void,
                           revert: (() -> Void)? = nil) {
        optimistic()
        Haptics.soft()
        Task {
            do {
                try await writer.vote(itemID: id, action: action)
            } catch {
                if let revert { revert() } else { voteStore.clearVote(id) }
                Haptics.warning()
                webTask = .item(itemID: id)
            }
        }
    }

    private func restoreVote(_ id: Int, _ previous: VoteDirection?) {
        switch previous {
        case .up: voteStore.markUpvoted(id)
        case .down: voteStore.markDownvoted(id)
        case .none: voteStore.clearVote(id)
        }
    }

    /// Open the native composer for a top-level comment or a reply.
    private func compose(parentID: Int, title: String, context: String?) {
        composeTarget = ComposeTarget(kind: .comment(parentID: parentID), storyID: story.id, title: title, context: context)
    }

    /// Whether `comment` is the signed-in user's and still within HN's ~2h edit window.
    private func canEdit(_ comment: FlatComment) -> Bool {
        guard canInteract, let me = account.username, comment.author == me else { return false }
        guard let date = comment.date else { return true } // unknown age — let HN decide
        return Date().timeIntervalSince(date) < Self.editWindow
    }
    private static let editWindow: TimeInterval = 2 * 60 * 60

    /// Fetch the comment's raw source, then open the editor prefilled with it.
    private func edit(_ comment: FlatComment) {
        Task {
            do {
                let poster = HNWebWriter(dataStore: account.dataStore)
                let source = try await poster.fetchEditableSource(commentID: comment.id)
                composeTarget = ComposeTarget(
                    kind: .edit(commentID: comment.id),
                    storyID: story.id,
                    title: "Edit Comment",
                    context: nil,
                    initialText: source
                )
            } catch {
                Haptics.warning()
                editError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load the comment for editing."
            }
        }
    }

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBaseline ?? settings.readingTextScale
                if pinchBaseline == nil { pinchBaseline = base }
                let proposed = base * value.magnification
                let clamped = min(SettingsStore.maxTextScale, max(SettingsStore.minTextScale, proposed))
                // Snap to 0.05 steps to avoid a flood of persisted writes.
                let snapped = (clamped * 20).rounded() / 20
                if snapped != settings.readingTextScale {
                    settings.readingTextScale = snapped
                }
            }
            .onEnded { _ in
                pinchBaseline = nil
                Haptics.soft()
            }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if let (label, color) = categoryTag {
                TagBadge(text: label, color: color)
            }

            Text(story.displayTitle)
                .font(.reader(23 * textScale, .bold, relativeTo: .title2))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let url = story.articleURL {
                articleCard(url: url)
            }

            if story.isTextPost, let text = story.text, !text.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(Array(HTMLRenderer.render(text).enumerated()), id: \.offset) { _, block in
                        CommentBlockView(block: block)
                    }
                }
                .padding(.top, Spacing.xxs)
            }

            metaBar
            if canInteract { actionBar }
        }
        .padding(Spacing.l)
        .background(Theme.surface)
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.m) {
            if canVote(story.author) {
                Button {
                    toggleUpvote(story.id)
                } label: {
                    Label(voteStore.hasUpvoted(story.id) ? "Upvoted" : "Upvote",
                          systemImage: voteStore.hasUpvoted(story.id) ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.upvote)

                Button {
                    toggleDownvote(story.id)
                } label: {
                    Label(voteStore.hasDownvoted(story.id) ? "Downvoted" : "Downvote",
                          systemImage: voteStore.hasDownvoted(story.id) ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.downvote)
            }

            Button {
                compose(parentID: story.id, title: "Add Comment", context: story.displayTitle)
            } label: {
                Label("Comment", systemImage: "bubble.left")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(settings.accent.color)

            Spacer(minLength: 0)
        }
    }

    /// Story score, adjusted by our own optimistic vote (HN's API count lags).
    private var displayedPoints: Int {
        story.points + voteStore.scoreDelta(for: story.id)
    }

    private func articleCard(url: URL) -> some View {
        Button {
            Haptics.tap()
            openArticle(url)
        } label: {
            HStack(spacing: Spacing.m) {
                FaviconView(host: story.host, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(story.host ?? url.absoluteString)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("Read article")
                        .font(AppFont.meta)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 18))
                    .foregroundStyle(settings.accent.color)
            }
            .padding(Spacing.m)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.card)
        .accessibilityLabel("Read article from \(story.host ?? "link")")
        .accessibilityHint("Opens the linked page")
    }

    /// Compact meta line mirroring the story list row: score, comments, a
    /// tappable author, and the posting time — no oversized author card.
    private var metaBar: some View {
        HStack(spacing: Spacing.m) {
            if story.kind != .job {
                StatLabel(systemImage: "arrow.up", value: "\(displayedPoints)", tint: Theme.upvote)
                    .accessibilityLabel("\(displayedPoints) points")
                StatLabel(systemImage: "bubble.left", value: "\(vm.commentCount)")
                    .accessibilityLabel("\(vm.commentCount) comments")
            }
            NavigationLink(value: UserRoute(username: story.author)) {
                StatLabel(systemImage: "person", value: story.author).lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Posted by \(story.author)")
            .accessibilityHint("View profile")
            StatLabel(systemImage: "clock", value: RelativeTime.compact(story.date))
                .accessibilityLabel("Posted \(RelativeTime.verbose(story.date))")
            Spacer(minLength: 0)
        }
        .font(AppFont.meta)
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Comments

    private func commentsSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Comments")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if vm.commentCount > 0 {
                    Text("\(vm.commentCount)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if case .loaded = vm.phase, vm.commentCount > 0 {
                    sortMenu
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { vm.toggleCollapseAll() }
                    } label: {
                        Label(vm.allTopLevelCollapsed ? "Expand All" : "Collapse All",
                              systemImage: vm.allTopLevelCollapsed
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.iconOnly)
                    }
                    .foregroundStyle(settings.accent.color)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)

            Divider().background(Theme.hairline)

            commentsContent(proxy: proxy)
        }
        .padding(.top, Spacing.s)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort Comments", selection: Binding(
                get: { settings.commentSort },
                set: { newValue in
                    Haptics.selection()
                    withAnimation(.snappy) { settings.commentSort = newValue }
                }
            )) {
                ForEach(CommentSort.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.semibold))
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(settings.accent.color)
    }

    @ViewBuilder private func commentsContent(proxy: ScrollViewProxy) -> some View {
        switch vm.phase {
        case .loading:
            VStack(spacing: Spacing.l) {
                ForEach(0..<5, id: \.self) { _ in SkeletonStoryRow().padding(.horizontal, Spacing.l) }
            }
            .padding(.top, Spacing.l)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await vm.load() } }
        case .loaded:
            if vm.visibleComments.isEmpty {
                EmptyStateView(systemImage: "bubble.left.and.bubble.right",
                               title: "No comments yet",
                               message: "Be the first to join the discussion on Hacker News.")
            } else {
                let rows = vm.visibleComments
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, comment in
                        CommentRow(
                            comment: comment,
                            opAuthor: story.author,
                            isCollapsed: vm.isCollapsed(comment.id),
                            canInteract: canInteract,
                            canVote: canVote(comment.author),
                            isUpvoted: voteStore.hasUpvoted(comment.id),
                            isDownvoted: voteStore.hasDownvoted(comment.id),
                            canEdit: canEdit(comment),
                            onReply: { compose(parentID: comment.id, title: "Reply", context: "Replying to \(comment.author)") },
                            onUpvote: { toggleUpvote(comment.id) },
                            onDownvote: { toggleDownvote(comment.id) },
                            onEdit: { edit(comment) },
                            onSkip: { level in
                                performSkip(from: comment.id, level: level, proxy: proxy)
                            },
                            onQuoteTap: { quote in
                                performQuoteJump(from: comment.id, quote: quote, proxy: proxy)
                            },
                            highlightTint: highlightedComment == comment.id
                                ? settings.accent.color.opacity(0.14) : nil
                        ) {
                            withAnimation(.snappy(duration: 0.22)) {
                                vm.toggleCollapse(comment.id)
                            }
                        }
                        // Inset each divider to line up with the content of the
                        // comment below it, so depth reads by position: a new
                        // top-level thread gets a full-bleed line, while deeper
                        // replies get progressively shorter, inset lines.
                        let nextDepth = index + 1 < rows.count ? rows[index + 1].depth : 0
                        let startsNewSection = nextDepth == 0
                        Divider()
                            .background(startsNewSection ? Theme.separator : Theme.hairline)
                            .padding(.leading, startsNewSection ? 0 : CommentRow.contentInset(forDepth: nextDepth))
                    }
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ShareLink(item: story.articleURL ?? story.hnURL,
                      subject: Text(story.displayTitle),
                      message: Text(story.hnURL.absoluteString)) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                toggleSaved()
                Haptics.soft()
            } label: {
                Image(systemName: isSaved
                    ? (usesFavorites ? "star.fill" : "bookmark.fill")
                    : (usesFavorites ? "star" : "bookmark"))
            }
            .accessibilityLabel(isSaved ? "Remove" : (usesFavorites ? "Add to favorites" : "Save story"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let url = story.articleURL {
                    Button { openArticle(url) } label: { Label("Open Link", systemImage: "safari") }
                }
                Button { openURL(story.hnURL) } label: {
                    Label("Open in Hacker News", systemImage: "globe")
                }
                Button {
                    UIPasteboard.general.url = story.articleURL ?? story.hnURL
                    Haptics.tap()
                } label: {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                Divider()
                if readStore.isRead(item.id) {
                    Button { readStore.markUnread(item.id) } label: {
                        Label("Mark as Unread", systemImage: "circle")
                    }
                } else {
                    Button { readStore.markRead(item.id) } label: {
                        Label("Mark as Read", systemImage: "checkmark.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More actions")
        }
    }

    // MARK: Helpers

    private var categoryTag: (String, Color)? {
        switch story.kind {
        case .job: return ("Job", Theme.upvote)
        default:
            let t = story.displayTitle.lowercased()
            if t.hasPrefix("ask hn") { return ("Ask HN", Theme.link) }
            if t.hasPrefix("show hn") { return ("Show HN", Theme.positive) }
            return nil
        }
    }
}
