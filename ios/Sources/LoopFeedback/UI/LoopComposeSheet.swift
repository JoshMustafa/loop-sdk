#if os(iOS)
import SwiftUI

/// Compose screen — "NEW BUG" / "NEW FEATURE". Hand-rolled (no Form) so the
/// look matches the design exactly: chunky kind cards, plain text fields
/// with thin borders, mono caps section labels, dashed auto-capture
/// disclosure.
struct LoopComposeSheet: View {
    @ObservedObject var model: LoopReporterModel
    let onSubmitted: (LoopSubmissionResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @FocusState private var titleFocus: Bool

    @State private var kind: LoopItem.Kind
    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var submitting = false
    @State private var errorText: String?

    private var dark: Bool { scheme == .dark }

    init(
        model: LoopReporterModel,
        initialKind: LoopItem.Kind = .bug,
        initialTitle: String = "",
        initialBody: String = "",
        onSubmitted: @escaping (LoopSubmissionResult) -> Void
    ) {
        self.model = model
        _kind = State(initialValue: initialKind)
        _title = State(initialValue: initialTitle)
        _bodyText = State(initialValue: initialBody)
        self.onSubmitted = onSubmitted
    }

    private static let minBodyChars = 10
    private static let maxTitleChars = 240

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBodyCount: Int { bodyText.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var bodyMeetsMinimum: Bool { trimmedBodyCount >= Self.minBodyChars }
    private var titleEmpty: Bool { trimmedTitle.isEmpty }
    private var titleApproachingMax: Bool { title.count >= Self.maxTitleChars - 20 }

    private var canSubmit: Bool {
        !submitting && !titleEmpty && bodyMeetsMinimum
    }

    var body: some View {
        ZStack {
            LoopColors.bg(dark: dark).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        kindCards
                        titleField
                        bodyField
                        autoCaptureDisclosure
                        if let errorText {
                            errorBanner(errorText)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
            }
        }
        .interactiveDismissDisabled(submitting)
        .onAppear { titleFocus = true }
    }

    // MARK: - Header (Cancel · NEW BUG · Send →)

    private var header: some View {
        let kindTitle = kind == .bug
            ? String(localized: "New bug", bundle: .module)
            : String(localized: "New feature", bundle: .module)
        return HStack(alignment: .center) {
            Button(action: { dismiss() }) {
                Text("Cancel", bundle: .module)
                    .font(LoopFont.sf(15, .regular))
                    .foregroundStyle(LoopColors.textSecondary(dark: dark))
            }
            Spacer()
            MonoCaps(text: kindTitle, size: 11, kerning: 1.2)
            Spacer()
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 4) {
                    if submitting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(LoopColors.onInk(dark: dark))
                    } else {
                        Text("Send →", bundle: .module)
                            .font(LoopFont.sf(13, .semibold))
                            .kerning(-0.15)
                            .foregroundStyle(LoopColors.onInk(dark: dark))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    LoopColors.ink(dark: dark).opacity(canSubmit ? 1 : 0.35),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    // MARK: - Kind picker (two chunky cards)

    private var kindCards: some View {
        HStack(spacing: 10) {
            kindCard(
                .bug,
                label: String(localized: "Bug", bundle: .module),
                sub: String(localized: "Something is broken", bundle: .module)
            )
            kindCard(
                .feature,
                label: String(localized: "Feature", bundle: .module),
                sub: String(localized: "I'd like this added", bundle: .module)
            )
        }
        .padding(.bottom, 22)
    }

    private func kindCard(_ k: LoopItem.Kind, label: String, sub: String) -> some View {
        let active = k == kind
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { kind = k }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(LoopFont.sf(15, .bold))
                    .kerning(-0.3)
                    .foregroundStyle(active
                        ? LoopColors.text(dark: dark)
                        : LoopColors.textSecondary(dark: dark))
                Text(sub)
                    .font(LoopFont.sf(12))
                    .kerning(-0.08)
                    .foregroundStyle(LoopColors.textTertiary(dark: dark))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                active ? LoopColors.surf(dark: dark) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        active ? LoopColors.ink(dark: dark) : LoopColors.separator(dark: dark),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Title input

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoCaps(text: String(localized: "Title", bundle: .module))
            TextField(
                "",
                text: $title,
                prompt: Text(
                    kind == .bug ? "What broke?" : "What would help?",
                    bundle: .module
                )
                .foregroundColor(LoopColors.textTertiary(dark: dark))
            )
            .focused($titleFocus)
            .textInputAutocapitalization(.sentences)
            .font(LoopFont.sf(16))
            .foregroundStyle(LoopColors.text(dark: dark))
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(LoopColors.surf(dark: dark), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LoopColors.separator(dark: dark), lineWidth: 1)
            )
            // Clamp at the backend's 240 limit so the user can't type past it.
            // (Single-arg onChange form for iOS 16 compatibility.)
            .onChange(of: title) { newValue in
                if newValue.count > Self.maxTitleChars {
                    title = String(newValue.prefix(Self.maxTitleChars))
                }
            }

            titleHint
        }
        .padding(.bottom, 18)
    }

    /// Title helper:
    ///   - Empty → `REQUIRED` in tertiary
    ///   - Filled, well under max → hidden (no clutter)
    ///   - Within 20 chars of the 240 cap → `N / 240 CHARACTERS`, red at the cap
    @ViewBuilder
    private var titleHint: some View {
        if titleEmpty {
            Text("Required", bundle: .module)
                .font(LoopFont.mono(10.5, .medium))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(LoopColors.textTertiary(dark: dark))
                .padding(.horizontal, 4)
        } else if titleApproachingMax {
            let atMax = title.count >= Self.maxTitleChars
            Text("\(title.count) / \(Self.maxTitleChars) characters", bundle: .module)
                .font(LoopFont.mono(10.5, .medium))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(atMax
                    ? LoopColors.downvote
                    : LoopColors.statusInProgress)  // amber as a warning
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Body (multi-line)

    private var bodyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoCaps(text: String(localized: "Description", bundle: .module))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $bodyText)
                    .font(LoopFont.sf(15))
                    .foregroundStyle(LoopColors.text(dark: dark))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 140, alignment: .topLeading)

                if bodyText.isEmpty {
                    Text("Steps to reproduce, what you expected, what actually happened…", bundle: .module)
                        .font(LoopFont.sf(15))
                        .foregroundStyle(LoopColors.textTertiary(dark: dark))
                        .lineSpacing(2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(LoopColors.surf(dark: dark), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LoopColors.separator(dark: dark), lineWidth: 1)
            )

            bodyHint
        }
        .padding(.bottom, 16)
    }

    /// Live character-count hint shown directly under the description.
    /// Idle (empty) → tertiary text. Started but under → red. Met → green.
    @ViewBuilder
    private var bodyHint: some View {
        let count = trimmedBodyCount
        let met = bodyMeetsMinimum
        let untouched = count == 0

        let color: Color = {
            if met { return LoopColors.statusOpen }
            if untouched { return LoopColors.textTertiary(dark: dark) }
            return LoopColors.downvote
        }()

        Group {
            if met {
                Text("✓ \(count) characters", bundle: .module)
            } else {
                Text("\(count) / \(Self.minBodyChars) characters minimum", bundle: .module)
            }
        }
        .font(LoopFont.mono(10.5, .medium))
        .kerning(0.6)
        .textCase(.uppercase)
        .foregroundStyle(color)
        .padding(.top, 8)
        .padding(.horizontal, 4)
    }

    // MARK: - Auto-capture disclosure

    private var autoCaptureDisclosure: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(LoopColors.subtleFill(dark: dark))
                Text(verbatim: "i")
                    .font(LoopFont.mono(12, .bold))
                    .foregroundStyle(LoopColors.text(dark: dark))
            }
            .frame(width: 22, height: 22)

            Text(disclosureAttributedText)
                .font(LoopFont.sf(12.5))
                .kerning(-0.08)
                .foregroundStyle(LoopColors.textSecondary(dark: dark))
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LoopColors.separator(dark: dark), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }

    /// Auto-capture disclosure rendered from a single localized markdown
    /// string. Backtick-delimited spans (e.g. `` `device` ``) become inline
    /// monospaced runs styled in the primary text colour — translators can
    /// reorder or rename the keywords as long as the backticks stay.
    private var disclosureAttributedText: AttributedString {
        let source = String(
            localized: "We attach `device`, `os`, `app version` and a session id automatically. No personal info is sent.",
            bundle: .module
        )
        guard var attr = try? AttributedString(markdown: source) else {
            return AttributedString(source)
        }
        let codeFont = LoopFont.mono(12.5)
        let codeColor = LoopColors.text(dark: dark)
        for run in attr.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].font = codeFont
                attr[run.range].foregroundColor = codeColor
            }
        }
        return attr
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(LoopFont.sf(13))
            .foregroundStyle(LoopColors.downvote)
            .padding(.top, 16)
    }

    private func submit() async {
        submitting = true
        errorText = nil
        defer { submitting = false }
        do {
            let result = try await model.submit(kind: kind, title: title, body: bodyText)
            onSubmitted(result)
        } catch let error as LoopError {
            errorText = displayMessage(for: error)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func displayMessage(for error: LoopError) -> String {
        switch error {
        case .invalidApiKey:
            return String(localized: "Loop SDK isn't configured correctly.", bundle: .module)
        case .badRequest(let m):
            return m ?? String(localized: "That didn't go through. Try again.", bundle: .module)
        case .notFound:
            return String(localized: "Couldn't reach Loop.", bundle: .module)
        case .serverError:
            return String(localized: "Loop is having trouble — try again in a moment.", bundle: .module)
        case .transport:
            return String(localized: "Network problem. Check your connection.", bundle: .module)
        case .decoding:
            return String(localized: "Got an unexpected response from Loop.", bundle: .module)
        case .unknown:
            return String(localized: "Something went wrong.", bundle: .module)
        }
    }
}
#endif
