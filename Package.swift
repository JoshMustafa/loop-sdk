// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Loop",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LoopCore", targets: ["LoopCore"]),
        .library(name: "LoopFeedback", targets: ["LoopFeedback"]),
        .library(name: "LoopDiagnostics", targets: ["LoopDiagnostics"]),
    ],
    targets: [
        .target(
            name: "LoopCore",
            path: "ios/Sources/LoopCore",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "LoopFeedback",
            dependencies: ["LoopCore"],
            path: "ios/Sources/LoopFeedback",
            resources: [
                .process("PrivacyInfo.xcprivacy"),
                .process("Resources/Localizable.xcstrings"),
            ]
        ),
        .target(
            name: "LoopDiagnostics",
            dependencies: ["LoopCore"],
            path: "ios/Sources/LoopDiagnostics"
        ),
        .target(name: "LoopTestSupport", path: "ios/Tests/LoopTestSupport"),
        .testTarget(name: "LoopCoreTests", dependencies: ["LoopCore", "LoopTestSupport"], path: "ios/Tests/LoopCoreTests"),
        .testTarget(name: "LoopFeedbackTests", dependencies: ["LoopFeedback", "LoopTestSupport"], path: "ios/Tests/LoopFeedbackTests"),
        .testTarget(name: "LoopDiagnosticsTests", dependencies: ["LoopDiagnostics", "LoopTestSupport"], path: "ios/Tests/LoopDiagnosticsTests"),
    ]
)
