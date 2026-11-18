// swift-tools-version: 5.9

// For Capacitor apps on Swift Package Manager. As the podspec does for CocoaPods, the target compiles the iOS SDK's sources
// (Core/), which scripts/vendor-native.mjs copies in before packing. Capacitor names the package and its product after the npm package
// (@datatalks-ab/push-capacitor: DatatalksAbPushCapacitor), so both names have to follow it.
import PackageDescription

let package = Package(
    name: "DatatalksAbPushCapacitor",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "DatatalksAbPushCapacitor", targets: ["DataTalksPushPlugin"]),
        // For the app's notification service extension target: pictures and delivery receipts, without Capacitor.
        .library(name: "DataTalksPushExtension", targets: ["DataTalksPushExtension"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", "6.0.0" ..< "9.0.0"),
    ],
    targets: [
        .target(
            name: "DataTalksPushPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
            ],
            path: "ios/Sources/DataTalksPushPlugin",
            resources: [.copy("Core/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "DataTalksPushExtension",
            path: "ios/Extension",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
    ]
)
