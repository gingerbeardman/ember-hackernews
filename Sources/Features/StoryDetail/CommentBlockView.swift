import SwiftUI

/// Renders a single parsed `CommentBlock` (paragraph, quote, or code) natively.
/// Used for both comment bodies and self/text posts.
struct CommentBlockView: View {
    let block: CommentBlock
    /// When set, tapping a quote's accent bar reports its plain text so the
    /// caller can jump to the quoted (up-thread) comment.
    var onQuoteTap: ((String) -> Void)? = nil

    @Environment(SettingsStore.self) private var settings

    private var scale: CGFloat { CGFloat(settings.readingTextScale) }
    private var bodyFont: Font { .reader(15.5 * scale, .regular, relativeTo: .callout) }

    var body: some View {
        switch block {
        case .text(let attributed):
            Text(styled(attributed))
                .font(bodyFont)
                .lineSpacing(AppFont.readingLineSpacing * scale)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let attributed):
            HStack(alignment: .top, spacing: Spacing.s) {
                quoteBar(for: attributed)
                Text(attributed)
                    .font(bodyFont.italic())
                    .lineSpacing(AppFont.readingLineSpacing * scale)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13 * scale, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(Spacing.m)
            }
            .background(Theme.surfacePressed)
            .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
    }

    /// The accent bar beside a quote. When a tap handler is provided it becomes a
    /// control that jumps to the quoted comment; the hit area is widened well past
    /// the 3pt bar without disturbing the text's position.
    @ViewBuilder private func quoteBar(for attributed: AttributedString) -> some View {
        let bar = RoundedRectangle(cornerRadius: 1.5)
            .fill(settings.accent.color.opacity(0.55))
            .frame(width: 3)
        if let onQuoteTap {
            bar
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.tap()
                    onQuoteTap(String(attributed.characters))
                }
                .padding(.horizontal, -8)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Go to quoted comment")
        } else {
            bar
        }
    }

    /// Optionally underline links so they remain identifiable without color.
    private func styled(_ attributed: AttributedString) -> AttributedString {
        guard settings.underlineLinks else { return attributed }
        var copy = attributed
        for run in copy.runs where run.link != nil {
            copy[run.range].underlineStyle = .single
        }
        return copy
    }
}
