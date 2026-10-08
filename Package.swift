// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArtemisUISDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ArtemisUISDK", targets: ["ArtemisUISDK"]),
        .library(name: "ArtemisSocketSDK", targets: ["ArtemisSocketSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "ArtemisSocketSDK",
            dependencies: ["Yams"],
            path: "Sources/ArtemisSocketSDK",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "ArtemisUISDK",
            dependencies: ["ArtemisSocketSDK"],
            path: "Sources/ArtemisUISDK"
        ),
        .testTarget(
            name: "ArtemisUISDKTests",
            dependencies: ["ArtemisUISDK"],
            path: "Tests/ArtemisUISDKTests"
        ),
    ]
)
