// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PetSnapshot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../PetArchiveKit")
    ],
    targets: [
        .executableTarget(
            name: "PetSnapshot",
            dependencies: ["PetArchiveKit"],
            path: "Sources/PetSnapshot"
        )
    ]
)
