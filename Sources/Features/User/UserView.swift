import SwiftUI

struct UserView: View {
    let username: String
    @State private var vm: UserViewModel
    @Environment(\.openURL) private var openURL
    @Environment(AccountStore.self) private var account

    init(username: String) {
        self.username = username
        _vm = State(initialValue: UserViewModel(username: username))
    }

    /// True when this is the signed-in user's own profile (the Me tab), where we
    /// surface saved-search management.
    private var isOwnProfile: Bool { username == account.username }

    var body: some View {
        ScrollView {
            switch vm.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await vm.load() } }
            case .loaded:
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if !vm.submissions.isEmpty { submissionsSection }
                    if !vm.comments.isEmpty { commentsSection }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOwnProfile {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SavedSearchesView() } label: {
                        Image(systemName: "bell.badge")
                    }
                    .accessibilityLabel("Saved Searches")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openURL(URL(string: "https://news.ycombinator.com/user?id=\(username)")!)
                } label: {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("Open profile on Hacker News")
            }
        }
        .task { await vm.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(spacing: Spacing.m) {
                MonogramAvatar(name: username, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(username)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let joined = vm.user?.createdDate {
                        Text("Joined \(RelativeTime.absolute(joined))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: Spacing.s) {
                statTile(value: formatted(vm.user?.karmaValue ?? 0), label: "Karma", icon: "star.fill")
                statTile(value: "\(vm.user?.submissionCount ?? 0)", label: "Submissions", icon: "doc.text.fill")
            }

            if let about = vm.user?.about, !about.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("About")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(Array(HTMLRenderer.render(about).enumerated()), id: \.offset) { _, block in
                        CommentBlockView(block: block)
                    }
                }
                .padding(.top, Spacing.xs)
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
    }

    private func statTile(value: String, label: String, icon: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.upvote)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    private var submissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Submissions")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.s)

            ForEach(vm.submissions) { story in
                NavigationLink(value: story) {
                    StoryRow(item: story)
                        .padding(.horizontal, Spacing.l)
                }
                .buttonStyle(.plain)
                Divider().background(Theme.hairline).padding(.leading, Spacing.l)
            }
        }
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Comments")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.s)

            ForEach(vm.comments) { comment in
                commentRow(comment)
                Divider().background(Theme.hairline).padding(.leading, Spacing.l)
            }
        }
    }

    @ViewBuilder private func commentRow(_ comment: UserComment) -> some View {
        let content = VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(HTMLRenderer.render(comment.html).enumerated()), id: \.offset) { _, block in
                CommentBlockView(block: block)
            }
            HStack(spacing: 4) {
                if let title = comment.storyTitle {
                    Text("on \(title)").lineLimit(1)
                }
                if let date = comment.date {
                    Text("·")
                    Text(RelativeTime.compact(date))
                }
            }
            .font(AppFont.meta)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)

        if let storyID = comment.storyID {
            NavigationLink(value: HNItem(id: storyID, title: comment.storyTitle)) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func formatted(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName))
    }
}
