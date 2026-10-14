import Foundation

extension Bundle {
    /// LoopFeedback's resources (strings, privacy manifest): `Bundle.module`
    /// under SwiftPM, the `LoopFeedback` resource bundle under CocoaPods.
    static var loopFeedback: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        let host = Bundle(for: LoopFeedbackBundleToken.self)
        if let url = host.url(forResource: "LoopFeedback", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return host
        #endif
    }
}

private final class LoopFeedbackBundleToken {}
