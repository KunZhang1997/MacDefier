// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UninstallHelperKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UninstallHelperCore", targets: ["UninstallHelperCore"]),
        .library(name: "UninstallHelperIPC", targets: ["UninstallHelperIPC"]),
        .library(name: "UninstallHelperClient", targets: ["UninstallHelperClient"])
    ],
    targets: [
        .target(name: "UninstallHelperCore"),
        .target(name: "UninstallHelperIPC", dependencies: ["UninstallHelperCore"]),
        .target(name: "UninstallHelperClient", dependencies: ["UninstallHelperCore", "UninstallHelperIPC"]),
        .testTarget(name: "UninstallHelperCoreTests", dependencies: ["UninstallHelperCore", "UninstallHelperIPC"]),
        .testTarget(name: "UninstallHelperIPCTests", dependencies: ["UninstallHelperIPC"]),
        .testTarget(name: "UninstallHelperClientTests", dependencies: ["UninstallHelperClient", "UninstallHelperIPC"])
    ]
)
