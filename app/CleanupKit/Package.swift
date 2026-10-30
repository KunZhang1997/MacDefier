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
    dependencies: [.package(path: "../UninstallHelperKit")],
    targets: [
        .target(
            name: "CleanupKit",
            dependencies: [.product(name: "UninstallHelperClient", package: "UninstallHelperKit"),
                           .product(name: "UninstallHelperCore", package: "UninstallHelperKit"),
                           .product(name: "UninstallHelperIPC", package: "UninstallHelperKit")],
            path: "Sources"
        ),
        .testTarget(
            name: "CleanupKitTests",
            dependencies: ["CleanupKit"],
            path: "Tests/CleanupKitTests"
        )
    ]
)
