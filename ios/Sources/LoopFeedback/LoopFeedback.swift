import Foundation
import LoopCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The bug & feature reporter. Call `Loop.configure` first, then present
/// `LoopFeedbackView()` in a sheet, or call `LoopFeedback.present(from:)`
/// from UIKit. `LoopComposerView` opens straight on the compose form.
public enum LoopFeedback {
    #if canImport(UIKit) && os(iOS)
    /// UIKit convenience: presents `LoopFeedbackView` modally.
    @MainActor
    public static func present(from presenter: UIViewController) {
        let controller = UIHostingController(rootView: LoopFeedbackView())
        presenter.present(controller, animated: true)
    }
    #endif

    #if os(iOS)
    /// Builds the view model from the shared runtime. Crashes with a clear
    /// message if `Loop.configure` was never called — better during
    /// integration than a silent 401.
    @MainActor
    static func makeModel() -> LoopReporterModel {
        let runtime = LoopRuntime.shared
        guard let http = runtime.http(), let configuration = runtime.configuration else {
            fatalError("Loop.configure(apiKey:) must be called before presenting LoopFeedbackView")
        }
        return LoopReporterModel(
            client: FeedbackClient(http: http),
            reporterId: runtime.reporterId,
            sessionId: runtime.sessionId,
            tierProvider: configuration.options.tierProvider
        )
    }
    #endif
}
