#if os(iOS)
import SwiftUI

/// Single row in the bug / feature list. Edge-to-edge — separators are
/// painted by the parent list, no card chrome here.
struct LoopItemRow: View {
    let item: LoopItem
    let onVote: (VoteDir?) -> Void

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                // ID + kind tag + status
                HStack(spacing: 8) {
                    Text(item.id)
                        .font(LoopFont.mono(10.5, .regular))
                        .kerning(0.4)
                        .foregroundStyle(LoopColors.textTertiary(dark: dark))
                    LoopKindTag(kind: item.kind)
                    LoopStatusLabel(status: item.status)
                }

                Text(item.title)
                    .font(LoopFont.sf(15.5, .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(LoopColors.text(dark: dark))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // when · replies
                HStack(spacing: 14) {
                    Text("\(item.whenLabel) ago", bundle: .module)
                        .font(LoopFont.mono(10.5, .medium))
                        .kerning(0.4)
                        .textCase(.uppercase)
                    if item.replyCount > 0 {
                        Text("\(item.replyCount) replies", bundle: .module)
                            .font(LoopFont.mono(10.5, .medium))
                            .kerning(0.4)
                            .textCase(.uppercase)
                    }
                }
                .foregroundStyle(LoopColors.textTertiary(dark: dark))
            }

            Spacer(minLength: 8)

            LoopVoteControl(
                votes: item.votes,
                my: item.my,
                onVote: onVote
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
#endif
