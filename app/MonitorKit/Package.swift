// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitorKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MonitorKit", targets: ["MonitorKit"])
    ],
    targets: [
        .target(
            name: "MonitorKit",
            path: "Sources"
        ),
        .testTarget(
            name: "MonitorKitTests",
            dependencies: ["MonitorKit"],
            path: "Tests"
        ),
    ]
)
