// swift-tools-version: 5.9

// At the repository root because SwiftPM reads a remote package's manifest from there. The code lives in sdks/ios/.
// SwiftPM only resolves plain semantic version tags, which is how every release is tagged (e.g. 0.5.0-beta.1).
import PackageDescription

let package = Package(
    name: "DataTalksPush",
    // iOS 14 covers every API the sources use (Logger, .banner and .list, .ephemeral) and matches Capacitor 7's minimum.
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "DataTalksPush", targets: ["DataTalksPush"]),
        // For the app's notification service extension: pictures and delivery receipts. Self-contained and extension-safe, so the
        // extension never links the app's runtime.
        .library(name: "DataTalksPushExtension", targets: ["DataTalksPushExtension"]),
    ],
    targets: [
        .target(
            name: "DataTalksPush",
            path: "sdks/ios/Sources/DataTalksPush",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "DataTalksPushExtension",
            path: "sdks/ios/Sources/DataTalksPushExtension",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "DataTalksPushTests",
            dependencies: ["DataTalksPush", "DataTalksPushExtension"],
            path: "sdks/ios/Tests/DataTalksPushTests"
        ),
    ]
)
