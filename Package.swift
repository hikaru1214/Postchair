// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PostchairSwiftTests",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PostchairCore",
            targets: ["PostchairCore"]
        ),
    ],
    targets: [
        .target(
            name: "PostchairCore",
            path: "ui/Postchair",
            exclude: [
                "Assets.xcassets",
                "DashboardWindowView.swift",
                "PostchairApp.swift",
                "UIComponents.swift",
                "VisualEffectView.swift",
            ],
            sources: [
                "AppState.swift",
                "BackendClient.swift",
                "BackendProcessManager.swift",
                "Models.swift",
            ]
        ),
        .testTarget(
            name: "PostchairCoreTests",
            dependencies: ["PostchairCore"],
            path: "ui/Tests/PostchairCoreTests"
        ),
    ]
)
