import XCTest
@testable import CleanupKit

final class ContainerOwnershipTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home").path }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ContainerOwnership-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/Library/Containers", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/Library/Group Containers", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func writeContainer(_ bundleID: String, metadataID: String? = nil) throws -> String {
        let path = home + "/Library/Containers/\(bundleID)"
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let metadataID {
            let metadata: NSDictionary = [
                "MCMMetadataIdentifier": metadataID,
                "Owners": [["signingIdentifier": metadataID, "teamIdentifier": "TEAM123"]],
                "application_bundle": "/Applications/Old.app"
            ]
            try metadata.write(toFile: path + "/.com.apple.containermanagerd.metadata.plist", atomically: true)
        }
        return path
    }

    private func liveApp(_ bundleID: String) throws -> InstalledApp {
        let path = root.appendingPathComponent("Live.app", isDirectory: true).path
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return InstalledApp(name: "Live", bundleIdentifier: bundleID, path: path, version: "1", bytes: 0, isSystemLocation: false, canTrashAppBundle: true)
    }

    func testMetadataConsistentUninstalledContainerIsVerifiedOrphan() throws {
        let path = try writeContainer("com.example.game", metadataID: "com.example.game")
        let item = ContainerOwnershipScanner.inspect(path: path, isGroupContainer: false, installed: [])
        XCTAssertEqual(item.bundleID, "com.example.game")
        XCTAssertEqual(item.confidence, .verifiedOrphan)
        XCTAssertTrue(item.evidence.contains { $0.contains("MCMMetadataIdentifier") })
    }

    func testInstalledAppPreventsOrphanClassification() throws {
        let path = try writeContainer("com.example.game", metadataID: "com.example.game")
        let item = ContainerOwnershipScanner.inspect(path: path, isGroupContainer: false, installed: [try liveApp("com.example.game")])
        XCTAssertEqual(item.confidence, .installedOwner)
    }

    func testConflictingMetadataNeverBecomesDeletable() throws {
        let path = try writeContainer("com.example.game", metadataID: "com.example.other")
        let item = ContainerOwnershipScanner.inspect(path: path, isGroupContainer: false, installed: [])
        XCTAssertEqual(item.confidence, .ambiguous)
    }

    func testSystemAndGroupContainersAreNotCandidates() throws {
        let system = try writeContainer("com.apple.Safari", metadataID: "com.apple.Safari")
        XCTAssertEqual(ContainerOwnershipScanner.inspect(path: system, isGroupContainer: false, installed: []).confidence, .protected)

        let group = home + "/Library/Group Containers/group.com.example.game"
        try fm.createDirectory(atPath: group, withIntermediateDirectories: true)
        let metadata: NSDictionary = ["MCMMetadataIdentifier": "com.example.game"]
        try metadata.write(toFile: group + "/.com.apple.containermanagerd.metadata.plist", atomically: true)
        XCTAssertEqual(ContainerOwnershipScanner.inspect(path: group, isGroupContainer: true, installed: []).confidence, .ambiguous)
    }

    func testContainerScanIsNotCappedAtSixHundredEntries() throws {
        for index in 0..<620 {
            let path = try writeContainer("com.example.\(index)", metadataID: "com.example.\(index)")
            _ = path
        }
        XCTAssertEqual(ContainerOwnershipScanner.scan(home: home, installed: []).filter { $0.confidence == .verifiedOrphan }.count, 620)
    }

    func testOrphanScanDoesNotMeasureInstalledOrProtectedContainers() throws {
        let live = try writeContainer("com.example.live", metadataID: "com.example.live")
        let system = try writeContainer("com.apple.example", metadataID: "com.apple.example")
        let orphan = try writeContainer("com.example.removed", metadataID: "com.example.removed")
        let unknown = try writeContainer("com.example.unknown")
        var measured: [String] = []

        let items = OrphanScanner.scanContainerOrphans(
            installed: [try liveApp("com.example.live")], home: home,
            measureSize: { path in
                measured.append(path)
                return 128 * 1024
            }
        )

        XCTAssertEqual(Set(measured), Set([orphan]))
        XCTAssertFalse(measured.contains(live))
        XCTAssertFalse(measured.contains(system))
        XCTAssertEqual(items.first { $0.path == orphan }?.risk, .caution)
        XCTAssertNil(items.first { $0.path == unknown })
        XCTAssertTrue(items.allSatisfy { !$0.isSelected })
    }
}
