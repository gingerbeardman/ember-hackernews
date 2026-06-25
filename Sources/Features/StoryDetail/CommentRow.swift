import SwiftUI

/// A single comment with depth-based thread indicators, collapse support, an
/// author profile link, and native rendering of its HTML body.
struct CommentRow: View {
    let comment: FlatComment
    let opAuthor: String?
    let isCollapsed: Bool
    var canInteract: Bool = false
    /// Whether the upvote button is offered — false for your own comments, which
    /// HN won't let you vote on (no arrow), while reply/edit stay available.
    var canVote: Bool = false
    var isVoted: Bool = false
    var canEdit: Bool = false
    var onReply: () -> Void = {}
    var onVote: () -> Void = {}
    var onEdit: () -> Void = {}
    /// Tap on a depth rail: skip to the next comment at that level.
    var onSkip: (Int) -> Void = { _ in }
    /// Tap on a quote bar: the quoted text, for jumping to its source comment.
    var onQuoteTap: ((String) -> Void)? = nil
    /// Transient background tint when this row is the target of a quote jump.
    var highlightTint: Color? = nil
    let onToggle: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var isOP: Bool { opAuthor != nil && comment.author == opAuthor }
    private var blocks: [CommentBlock] { HTMLRenderer.render(comment.html) }

    private var indentPerLevel: CGFloat { typeSize.isAccessibilitySize ? 7 : 10 }
    private var cappedDepth: Int { min(comment.depth, 7) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Rails span the full row height (no vertical padding of their own),
            // so adjacent comments' lines read as continuous; the content keeps
            // its usual breathing room via its own vertical padding.
            ThreadIndicator(cappedDepth: cappedDepth, ownDepth: comment.depth, onSkip: onSkip)
                .padding(.trailing, Spacing.s)
                // A 2px inset top & bottom leaves a 4px gap (plus the divider)
                // between one comment's rails and the next, so they read as
                // related but distinct rather than one unbroken line.
                .padding(.vertical, Spacing.xxs)

            VStack(alignment: .leading, spacing: 7) {
                header

                if isCollapsed {
                    if comment.descendantCount > 0 {
                        Text("\(comment.descendantCount) hidden")
                            .font(AppFont.meta)
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                } else {
                    bodyContent
                    if comment.isPending {
                        Label("Posting… will appear once Hacker News updates", systemImage: "clock.arrow.circlepath")
                            .font(AppFont.meta)
                            .foregroundStyle(Theme.textTertiary)
                    } else if canInteract {
                        interactionBar
                    }
                }
            }
            .padding(.vertical, Spacing.m)
        }
        .padding(.leading, Spacing.xs)
        .padding(.trailing, Spacing.l)
        .contentShape(Rectangle())
        .background(highlightTint ?? Theme.background)
        .accessibilityActions {
            Button("Next comment at this level") { onSkip(comment.depth) }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            NavigationLink(value: UserRoute(username: comment.author)) {
                HStack(spacing: 6) {
                    MonogramAvatar(name: comment.author, size: 22)
                    Text(comment.author)
                        .font(AppFont.metaStrong)
                        .foregroundStyle(isOP ? Theme.upvote : Theme.textPrimary)
                    if isOP {
                        TagBadge(text: "OP", color: Theme.upvote)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOP ? "\(comment.author), original poster" : comment.author)
            .accessibilityHint("View profile")

            Spacer(minLength: Spacing.s)

            Button(action: {
                Haptics.tap()
                onToggle()
            }) {
                HStack(spacing: 5) {
                    if isCollapsed, comment.descendantCount > 0 {
                        Text("+\(comment.descendantCount)")
                            .font(AppFont.metaStrong)
                            .monospacedDigit()
                    }
                    Text(RelativeTime.compact(comment.date))
                        .font(AppFont.meta)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.vertical, 4)
                .padding(.leading, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed
                ? "Expand thread, \(comment.descendantCount) replies hidden"
                : "Collapse thread")
        }
    }

    private var interactionBar: some View {
        HStack(spacing: Spacing.l) {
            if canVote {
                Button {
                    Haptics.soft()
                    onVote()
                } label: {
                    Label(isVoted ? "Upvoted" : "Upvote",
                          systemImage: isVoted ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(AppFont.metaStrong)
                        .foregroundStyle(isVoted ? Theme.upvote : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isVoted)
            }

            Button {
                Haptics.tap()
                onReply()
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .font(AppFont.metaStrong)
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if canEdit {
                Button {
                    Haptics.tap()
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(AppFont.metaStrong)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .accessibilityHidden(false)
    }

    /// Leading offset at which a comment of `depth` begins its content (avatar /
    /// text), measured from the row's leading edge. Used to inset thread dividers
    /// so a reply's divider lines up with the reply's text, conveying nesting by
    /// position rather than colour.
    static func contentInset(forDepth depth: Int) -> CGFloat {
        let capped = min(depth, 7)
        // leading row pad + (rail columns) + indicator trailing pad
        return Spacing.xs + CGFloat(capped + 1) * ThreadIndicator.columnWidth + Spacing.s
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                CommentBlockView(block: block, onQuoteTap: onQuoteTap)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Vertical rainbow thread bars conveying nesting depth (also positional via
/// indentation, so it remains legible without color). Every row carries at least
/// the leftmost (top-level) rail, and each rail is tappable to skip to the next
/// comment at that level.
private struct ThreadIndicator: View {
    /// Visual depth, capped so very deep threads don't run off the edge.
    let cappedDepth: Int
    /// The comment's true depth, used so the rightmost rail always navigates the
    /// comment's own level even when the visual depth is capped.
    let ownDepth: Int
    var onSkip: (Int) -> Void = { _ in }

    private static let palette: [Color] = [
        Color(hue: 0.07, saturation: 0.75, brightness: 0.95),
        Color(hue: 0.13, saturation: 0.70, brightness: 0.90),
        Color(hue: 0.33, saturation: 0.55, brightness: 0.75),
        Color(hue: 0.50, saturation: 0.60, brightness: 0.80),
        Color(hue: 0.60, saturation: 0.65, brightness: 0.85),
        Color(hue: 0.72, saturation: 0.55, brightness: 0.80),
        Color(hue: 0.85, saturation: 0.55, brightness: 0.80),
    ]
    fileprivate static let columnWidth: CGFloat = 9
    private static let barWidth: CGFloat = 2

    /// The nesting level a given rail column navigates. The rightmost rail maps
    /// to the comment's true depth; the rest map straight to their column index.
    private func level(for column: Int) -> Int {
        column == cappedDepth ? ownDepth : column
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0...cappedDepth, id: \.self) { column in
                let lvl = level(for: column)
                ZStack {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Self.palette[lvl % Self.palette.count].opacity(0.7))
                        .frame(width: Self.barWidth)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onSkip(lvl) }
                }
                .frame(width: Self.columnWidth)
            }
        }
        .accessibilityHidden(true)
    }
}
