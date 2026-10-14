#if os(iOS)
import SwiftUI

/// Confirmation screen after a successful submission. Big check, mono caps
/// "REPORT SENT · LP-####", huge uppercase headline, two buttons.
struct LoopSubmittedView: View {
    let itemId: String
    let onSeeBoard: () -> Void
    let onFileAnother: () -> Void

    /// Nil unless the project has `collect_email` on — the screen then looks
    /// exactly as it did before this feature existed, which is what the default
    /// configuration gets. Declared `var` and last so the memberwise initialiser
    /// defaults it to nil and the existing construction sites keep compiling
    /// unchanged.
    var onSubmitEmail: ((String) async -> Bool)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            LoopColors.bg(dark: dark).ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer(minLength: 0)

                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LoopColors.ink(dark: dark))
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(LoopColors.onInk(dark: dark))
                }
                .frame(width: 80, height: 80)

                VStack(spacing: 12) {
                    MonoCaps(
                        text: String(localized: "Report sent · \(itemId)", bundle: .module),
                        size: 11,
                        kerning: 1.4
                    )

                    Text("Thanks for the\nheads-up", bundle: .module)
                        .font(LoopFont.sf(32, .heavy))
                        .kerning(-0.8)
                        .multilineTextAlignment(.center)
                        .textCase(.uppercase)
                        .foregroundStyle(LoopColors.text(dark: dark))
                        .lineSpacing(2)

                    Text("The team's been pinged. You'll find your report on the board next to everyone else's.", bundle: .module)
                        .font(LoopFont.sf(15))
                        .kerning(-0.2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(LoopColors.textSecondary(dark: dark))
                        .frame(maxWidth: 300)
                        .lineSpacing(3)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 32)

                if let onSubmitEmail {
                    LoopEmailPrompt(onSubmit: onSubmitEmail)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                }

                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Button(action: onSeeBoard) {
                        Text("See the board", bundle: .module)
                            .font(LoopFont.sf(16, .bold))
                            .kerning(-0.2)
                            .foregroundStyle(LoopColors.onInk(dark: dark))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(LoopColors.ink(dark: dark), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: onFileAnother) {
                        Text("File another", bundle: .module)
                            .font(LoopFont.sf(16, .semibold))
                            .kerning(-0.2)
                            .foregroundStyle(LoopColors.text(dark: dark))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(LoopColors.separator(dark: dark), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 320)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
            }
        }
    }
}
#endif
