import Foundation
#if os(iOS)
import SwiftUI
#endif

/// Optional email capture, shown after a report is filed.
///
/// Post-submit on purpose: the report path stays frictionless, and someone who
/// declines still filed their bug. The copy has to carry a real consent decision
/// — this is the record that the reporter asked to be emailed — so it says what
/// will be sent and nothing more.
///
/// The type and its validator compile on every platform; only the SwiftUI view
/// is iOS-only. `swift test` builds for macOS, so an `#if os(iOS)` wrapped around
/// the whole type would put `isPlausible` out of reach of the one test that
/// covers it.
struct LoopEmailPrompt {
    #if os(iOS)
    let onSubmit: (String) async -> Bool

    @State private var email = ""
    @State private var phase: Phase = .asking
    @Environment(\.colorScheme) private var scheme
    #endif

    /// Named `Phase`, not `State`: a nested `State` shadows SwiftUI's property
    /// wrapper inside this type, and `@State` then fails to resolve as an attribute.
    enum Phase { case asking, sending, sent, failed }

    /// Catches typos before a pointless round-trip. Deliberately loose: strict
    /// address validation by regex is a known trap, and the double opt-in is what
    /// actually proves an address is real.
    static func isPlausible(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(" "), value.count >= 5 else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    /// Builds the `onSubmit` handler to hand `LoopSubmittedView`.
    ///
    /// Every error becomes `false`. The report is already filed and safe by the
    /// time this runs, so a failed capture must never surface as a failed
    /// report — the prompt just offers to try again.
    ///
    /// Defined once here rather than inlined at each construction site: there
    /// are two of them (`LoopReporterView` and `LoopComposerView`), and this is
    /// the type that defines the closure's contract.
    static func handler(client: LoopClient) -> (String) async -> Bool {
        { email in
            do {
                try await client.submitContact(email: email)
                return true
            } catch {
                return false
            }
        }
    }
}

#if os(iOS)
extension LoopEmailPrompt: View {
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 10) {
            if phase == .sent {
                Text("Check your inbox to confirm.", bundle: .module)
                    .font(LoopFont.sf(14))
                    .foregroundStyle(LoopColors.textSecondary(dark: dark))
                    .multilineTextAlignment(.center)
            } else {
                Text("Want a reply by email?", bundle: .module)
                    .font(LoopFont.sf(15, .semibold))
                    .foregroundStyle(LoopColors.text(dark: dark))

                TextField(String(localized: "your@email.com", bundle: .module), text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(LoopFont.sf(16))
                    .foregroundStyle(LoopColors.text(dark: dark))
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(LoopColors.separator(dark: dark), lineWidth: 1)
                    )

                Button(action: send) {
                    Text(phase == .sending ? String(localized: "Sending…", bundle: .module)
                                           : String(localized: "Email me the reply", bundle: .module))
                        .font(LoopFont.sf(16, .bold))
                        .foregroundStyle(LoopColors.onInk(dark: dark))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(LoopColors.ink(dark: dark), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!Self.isPlausible(email) || phase == .sending)
                .opacity(Self.isPlausible(email) && phase != .sending ? 1 : 0.5)

                // The consent record. It must say what will be sent, and it must
                // survive translation into all 16 locales.
                Text("Only used to tell you when the developer replies. Unsubscribe any time.", bundle: .module)
                    .font(LoopFont.sf(12))
                    .foregroundStyle(LoopColors.textSecondary(dark: dark))
                    .multilineTextAlignment(.center)

                if phase == .failed {
                    Text("That didn't send. You can try again.", bundle: .module)
                        .font(LoopFont.sf(12))
                        .foregroundStyle(LoopColors.textSecondary(dark: dark))
                }
            }
        }
        .frame(maxWidth: 320)
    }

    private func send() {
        phase = .sending
        Task {
            let ok = await onSubmit(email.trimmingCharacters(in: .whitespacesAndNewlines))
            phase = ok ? .sent : .failed
        }
    }
}
#endif
