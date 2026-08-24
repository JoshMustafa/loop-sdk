#if os(iOS)
import SwiftUI

/// Opens the Loop composer **directly**, pre-filled and ready to send —
/// skipping the board list that `LoopReporterView` shows first. Use this when
/// the host already knows what the user wants to report (e.g. a guided
/// troubleshooting flow that has gathered context) and wants them to land on
/// an editable, pre-populated report.
///
///     .fullScreenCover(isPresented: $reporting) {
///         LoopComposerView(
///             kind: .bug,
///             title: "Speaker audio plays from phone",
///             body: diagnosticSummary
///         )
///     }
///
/// On a successful submit it shows the same confirmation screen as
/// `LoopReporterView`, then dismisses back to the host.
public struct LoopComposerView: View {
    @StateObject private var model: LoopReporterModel
    @State private var submittedId: String?
    @Environment(\.dismiss) private var dismiss

    private let kind: LoopItem.Kind
    private let initialTitle: String
    private let initialBody: String

    public init(kind: LoopItem.Kind = .bug, title: String = "", body: String = "") {
        let runtime = LoopSDK.runtime()
        _model = StateObject(wrappedValue: runtime.makeReporterModel())
        self.kind = kind
        self.initialTitle = title
        self.initialBody = body
    }

    public var body: some View {
        LoopComposeSheet(
            model: model,
            initialKind: kind,
            initialTitle: initialTitle,
            initialBody: initialBody
        ) { result in
            submittedId = result.id
        }
        .preferredColorScheme(.dark)  // Brutalist palette is designed dark-first
        .task { await model.bootstrap() }
        .fullScreenCover(item: Binding(
            get: { submittedId.map(SubmittedId.init) },
            set: { if $0 == nil { submittedId = nil } }
        )) { wrap in
            LoopSubmittedView(
                itemId: wrap.id,
                // Both exits return to the host — there is no board to fall
                // back to in this entry point.
                onSeeBoard: { submittedId = nil; dismiss() },
                onFileAnother: { submittedId = nil; dismiss() },
                // Always passed: `collect_email` is not exposed to the SDK, so
                // the backend's 202-for-opted-out response is what makes this a
                // no-op for a project that has not opted in.
                onSubmitEmail: LoopEmailPrompt.handler(client: model.client)
            )
            .preferredColorScheme(.dark)
        }
    }

    private struct SubmittedId: Identifiable { let id: String }
}
#endif
