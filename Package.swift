// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArtemisUISDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ArtemisUISDK", targets: ["ArtemisUISDK"])],
    dependencies: [
        .package(url: "https://github.com/Koredotcom/artemis-ios-sdk", exact: "1.0.1")
    ],
    targets: [
        .target(name: "ArtemisUISDK", dependencies: [
            .product(name: "ArtemisSocketSDK", package: "artemis-ios-sdk")
        ], path: "Sources/ArtemisUISDK"),
        .testTarget(name: "ArtemisUISDKTests", dependencies: ["ArtemisUISDK"], path: "Tests/ArtemisUISDKTests")
    ]
)
