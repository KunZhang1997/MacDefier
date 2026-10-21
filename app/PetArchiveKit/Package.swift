// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PetArchiveKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PetArchiveKit", targets: ["PetArchiveKit"])
    ],
    dependencies: [
        .package(path: "../Vendor/ZIPFoundation")
    ],
    targets: [
        .target(
            name: "PetArchiveKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/PetArchiveKit"
        ),
        .testTarget(
            name: "PetArchiveKitTests",
            dependencies: [
                "PetArchiveKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Tests/PetArchiveKitTests"
        )
    ]
)
