// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CleanupKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CleanupKit", targets: ["CleanupKit"])
    ],
    targets: [
        .target(
            name: "CleanupKit",
            path: "Sources"
        ),
        .testTarget(
            name: "CleanupKitTests",
            dependencies: ["CleanupKit"],
            path: "Tests/CleanupKitTests"
        )
    ]
)
