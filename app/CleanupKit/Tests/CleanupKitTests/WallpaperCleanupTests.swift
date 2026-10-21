import Foundation
import XCTest
@testable import CleanupKit

final class WallpaperCleanupTests: XCTestCase {
    private let provider = "com.apple.wallpaper.choice.aerials"

    func testCurrentAerialIsNeverListedAndUnusedResourceIncludesThumbnail() throws {
        let fixture = try makeFixture(assetID: "ACTIVE")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let items = WallpaperCleanupPolicy.scan(home: fixture.rootURL.path)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "Unused Aerial")
        XCTAssertEqual(items.first?.category, .wallpaper)
        XCTAssertEqual(items.first?.allPaths.count, 2)
        XCTAssertFalse(PathGate.isSafeToTrash(fixture.activeVideo.path, home: fixture.rootURL.path))
        XCTAssertTrue(PathGate.isSafeToTrash(fixture.unusedVideo.path, home: fixture.rootURL.path))
    }

    func testShuffleAllProtectsEveryManifestAsset() throws {
        let fixture = try makeFixture(assetID: "shuffle-all-aerials")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        XCTAssertTrue(WallpaperCleanupPolicy.scan(home: fixture.rootURL.path).isEmpty)
        XCTAssertFalse(PathGate.isSafeToTrash(fixture.unusedVideo.path, home: fixture.rootURL.path))
    }

    func testUnreadableWallpaperStateFailsClosed() throws {
        let fixture = try makeFixture(assetID: "ACTIVE")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let index = fixture.rootURL.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        try FileManager.default.removeItem(at: index)

        XCTAssertTrue(WallpaperCleanupPolicy.scan(home: fixture.rootURL.path).isEmpty)
        XCTAssertFalse(PathGate.isSafeToTrash(fixture.unusedVideo.path, home: fixture.rootURL.path))
    }

    private struct Fixture {
        let rootURL: URL
        let activeVideo: URL
        let unusedVideo: URL
    }

    private func makeFixture(assetID: String) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WallpaperCleanupTests-\(UUID().uuidString)")
        let aerials = root.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
        let videos = aerials.appendingPathComponent("videos")
        let thumbnails = aerials.appendingPathComponent("thumbnails")
        let store = root.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store")
        let manifest = aerials.appendingPathComponent("manifest")
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: true)

        let activeVideo = videos.appendingPathComponent("ACTIVE.mov")
        let unusedVideo = videos.appendingPathComponent("UNUSED.mov")
        try Data(repeating: 1, count: 1024).write(to: activeVideo)
        try Data(repeating: 2, count: 2048).write(to: unusedVideo)
        try Data(repeating: 3, count: 256).write(to: thumbnails.appendingPathComponent("ACTIVE.png"))
        try Data(repeating: 4, count: 512).write(to: thumbnails.appendingPathComponent("UNUSED.png"))

        let manifestObject: [String: Any] = [
            "assets": [
                ["id": "ACTIVE", "accessibilityLabel": "Active Aerial", "includeInShuffle": true],
                ["id": "UNUSED", "accessibilityLabel": "Unused Aerial", "includeInShuffle": true]
            ]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject, options: [])
        try manifestData.write(to: manifest.appendingPathComponent("entries.json"))

        let config = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID],
            format: .binary,
            options: 0
        )
        let index: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Linked": [
                    "Content": [
                        "Choices": [["Provider": provider, "Configuration": config]]
                    ]
                ]
            ]
        ]
        let indexData = try PropertyListSerialization.data(
            fromPropertyList: index,
            format: .binary,
            options: 0
        )
        try indexData.write(to: store.appendingPathComponent("Index.plist"))

        return Fixture(rootURL: root, activeVideo: activeVideo, unusedVideo: unusedVideo)
    }
}
