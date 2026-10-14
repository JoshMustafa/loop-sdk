#if os(iOS)
import SwiftUI

/// Vertical up/count/down vote stack used in list rows. Reddit-style.
/// Active up = ink colour (white in dark / black in light). Active down =
/// `#FF453A`. Idle = tertiary text colour.
struct LoopVoteControl: View {
    let votes: Int
    let my: VoteDir?
    let onVote: (VoteDir?) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    private var upColor: Color {
        my == .up ? LoopColors.ink(dark: dark) : LoopColors.textTertiary(dark: dark)
    }

    private var downColor: Color {
        my == .down ? LoopColors.downvote : LoopColors.textTertiary(dark: dark)
    }

    var body: some View {
        VStack(spacing: 0) {
            chevron(direction: .up, color: upColor, system: "chevron.up")
            Text(verbatim: "\(votes)")
                .font(LoopFont.sf(15, .semibold).monospacedDigit())
                .foregroundStyle(LoopColors.text(dark: dark))
            chevron(direction: .down, color: downColor, system: "chevron.down")
        }
        .frame(width: 32)
    }

    @ViewBuilder
    private func chevron(direction: VoteDir, color: Color, system: String) -> some View {
        let active = my == direction
        Button {
            onVote(active ? nil : direction)
        } label: {
            Image(systemName: system)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(color)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(direction == .up ? "Vote up" : "Vote down", bundle: .module)
        )
    }
}
#endif
