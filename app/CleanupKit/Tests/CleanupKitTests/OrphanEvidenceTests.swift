import XCTest
@testable import CleanupKit

final class OrphanEvidenceTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home").path }
    private var missingApp: String { "/Applications/OrphanEvidence-\(root.lastPathComponent).app" }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("OrphanEvidence-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func app(_ name: String, id: String = "com.example.live", at path: String? = nil) -> InstalledApp {
        InstalledApp(name: name, bundleIdentifier: id, path: path ?? root.appendingPathComponent(name + ".app").path,
                     version: "1", bytes: 0, isSystemLocation: false, canTrashAppBundle: true)
    }

    private func container(_ id: String = "com.example.removed", appPaths: [String]? = nil) throws -> String {
        let path = home + "/Library/Containers/" + id
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        let owners = (appPaths ?? [missingApp]).map { ["application_bundle": $0, "signingIdentifier": id] }
        let metadata: NSDictionary = ["MCMMetadataIdentifier": id, "Owners": owners]
        XCTAssertTrue(metadata.write(toFile: path + "/.com.apple.containermanagerd.metadata.plist", atomically: true))
        return path
    }

    private func inspect(_ path: String, installed: [InstalledApp] = []) -> ContainerOwnership {
        ContainerOwnershipScanner.inspect(path: path, isGroupContainer: false, installed: installed)
    }

    func testUnmatchedScreenshotNamesAreExcludedBeforeSizing() throws {
        let names = ["FileProvider", "@hilo", "zspace", "CloudDocs", "ms-playwright", "yuque-desktop",
                     "Microsoft Edge", "Quark", "Trae", "Trae CN", "mockingbot-studio", "bilibili", "QoderCN",
                     "com.example.unknown", "com.example.unknown.plist"]
        for name in names {
            try fm.createDirectory(atPath: home + "/Library/Application Support/" + name, withIntermediateDirectories: true)
        }
        let installed = [app("极空间", id: "com.zentraedi.zspaceMacApp"), app("Trae"), app("Quark", id: "com.example.quark")]
        var measured: [String] = []
        let items = OrphanScanner.scanLibraryOrphans(
            installed: installed, cliInventory: [], containerOwnership: [], home: home,
            measureSize: { measured.append($0); return 2_000_000_000 }
        )
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(measured.isEmpty, "Unknown ownership must be rejected before recursive I/O")
    }

    func testConfirmedIdentityRetainsExactLibraryResidualsOnly() throws {
        let witness = inspect(try container())
        XCTAssertEqual(witness.confidence, .verifiedOrphan)
        let library = home + "/Library/Caches/"
        for name in ["com.example.removed", "com.example.removed.other", "removed"] {
            try fm.createDirectory(atPath: library + name, withIntermediateDirectories: true)
        }
        let items = OrphanScanner.scanLibraryOrphans(installed: [], cliInventory: [], containerOwnership: [witness], home: home,
                                                      measureSize: { _ in 128 * 1024 })
        XCTAssertEqual(items.map(\.path), [library + "com.example.removed"])
        XCTAssertTrue(items.allSatisfy { !$0.isSelected && $0.risk == .caution })
    }

    func testUnidentifiedLibraryEntriesAvoidRepeatedInstalledAppMatching() throws {
        let witness = inspect(try container())
        let installed = (0..<100).map { app("InstalledProduct\($0)", id: "com.example.live\($0)") }
        let start = Date()
        for index in 0..<2_000 {
            let name = "com.example.unknown\(index).plist"
            XCTAssertNil(OrphanScanner.libraryOrphanOwner(
                name: name, path: home + "/Library/Preferences/" + name,
                installed: installed, containerOwnership: [witness]))
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1, "Unknown IDs must not run the app-by-path matcher for every installed app")
        print("PERF_ORPHAN_REJECTION entries=2000 installed=100 elapsed_ms=\(elapsed * 1_000)")
    }

    func testMetadataWithoutOriginalApplicationIsNotUninstallEvidence() throws {
        let path = try container(appPaths: [])
        XCTAssertEqual(inspect(path).confidence, .ambiguous)
        var measured = false
        let items = OrphanScanner.scanContainerOrphans(installed: [], home: home,
            measureSize: { _ in measured = true; return 128 * 1024 })
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(measured)
    }

    func testOriginalApplicationProtectsDataOutsideInventoryRoots() throws {
        let path = root.appendingPathComponent("自定义位置/StillInstalled.app").path
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        XCTAssertEqual(inspect(try container(appPaths: [path])).confidence, .installedOwner)
    }

    func testMissingEmbeddedHelperDoesNotMakeItsParentAppAnOrphan() throws {
        let parent = root.appendingPathComponent("Live.app").path
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let path = try container(appPaths: [parent + "/Contents/XPCServices/old-helper.xpc"])
        XCTAssertEqual(inspect(path).confidence, .installedOwner)
    }

    func testInstalledParentBundleProtectsExtensionWithNoOriginalPath() throws {
        let path = try container("com.example.live.ShareExtension", appPaths: [])
        XCTAssertEqual(inspect(path, installed: [app("Live")]).confidence, .installedOwner)
    }

    func testShortDuplicateAppNamesProtectOldBundleIdentity() throws {
        let path = try container(appPaths: ["/Applications/Trae.app"])
        let installed = [app("Trae"), app("Trae", id: "com.example.other", at: root.appendingPathComponent("副本.app").path)]
        XCTAssertEqual(inspect(path, installed: installed).confidence, .installedOwner)
    }

    func testAnyRecordedOwnerStillPresentPreventsOrphanClassification() throws {
        let livePath = root.appendingPathComponent("Live.app").path
        try fm.createDirectory(atPath: livePath, withIntermediateDirectories: true)
        let path = try container(appPaths: [missingApp, livePath])
        XCTAssertEqual(inspect(path).confidence, .installedOwner)
    }

    func testConflictingSecondaryOwnerCannotBeIgnored() throws {
        let path = try container()
        let metadata: NSDictionary = [
            "MCMMetadataIdentifier": "com.example.removed",
            "Owners": [
                ["signingIdentifier": "com.example.removed", "application_bundle": missingApp],
                ["signingIdentifier": "com.example.live", "application_bundle": missingApp]
            ]
        ]
        XCTAssertTrue(metadata.write(toFile: path + "/.com.apple.containermanagerd.metadata.plist", atomically: true))
        XCTAssertEqual(inspect(path, installed: [app("Live")]).confidence, .ambiguous)
    }

    func testDetachedVolumesAndTemporaryAppLocationsAreUnknown() throws {
        for appPath in ["/Volumes/OrphanEvidenceUnavailable/Old.app", "/private/tmp/old-build/Old.app", "Old.app", "/Applications/../Old.app"] {
            let path = try container(appPaths: [appPath])
            XCTAssertEqual(inspect(path).confidence, .ambiguous, appPath)
        }
    }

    func testOldPreviewCannotAuthorizeUnidentifiedLibraryData() {
        for name in ["zspace", "FileProvider", "Trae", "com.example.unknown"] {
            XCTAssertTrue(TrashExecutor.shouldBlockOrphanPath(home + "/Library/Application Support/" + name,
                                                             installedApps: [app("Live")], containerOwnership: []))
        }
    }

    func testExecutionRechecksContainerEvidenceAfterAppReappears() throws {
        let path = try container()
        let witness = inspect(path)
        let data = home + "/Library/Caches/com.example.removed"
        let installed = [app("Live")]
        XCTAssertFalse(TrashExecutor.shouldBlockOrphanPath(data, installedApps: installed, containerOwnership: [witness]))
        let livePath = root.appendingPathComponent("Returned.app").path
        try fm.createDirectory(atPath: livePath, withIntermediateDirectories: true)
        _ = try container(appPaths: [livePath])
        XCTAssertTrue(TrashExecutor.shouldBlockOrphanPath(data, installedApps: installed, containerOwnership: [witness]))
    }

    func testReinstalledBundleOverridesPreviouslyVerifiedLibraryEvidence() throws {
        let witness = inspect(try container())
        XCTAssertTrue(TrashExecutor.shouldBlockOrphanPath(home + "/Library/Caches/com.example.removed",
            installedApps: [app("Renamed", id: "com.example.removed")], containerOwnership: [witness]))
    }

    func testVerifiedContainerPassesOrphanPreflightWithoutOpeningGenericGate() throws {
        let path = try container()
        let installed = [app("Live")]
        XCTAssertTrue(PathGate.isSafeOrphanToTrash(path, installedApps: installed, home: home))
        var candidate = CleanableItem(name: "Removed", path: path, bytes: 128_000,
                                      category: .orphans, isSelected: false, risk: .caution)
        candidate.isSelected = true
        let prepared = CleanupService.gatedExecutableItems(
            from: [candidate], expectedTargets: [candidate.id: [PathGate.normalize(path)]],
            installedApps: installed, home: home)
        XCTAssertEqual(prepared.flatMap(\.allPaths), [path])
        XCTAssertFalse(PathGate.isSafeOrphanToTrash(path, installedApps: nil, home: home))
        XCTAssertFalse(PathGate.isSafeOrphanToTrash(path, installedApps: [], home: home))
    }

    func testOrphanGateRejectsReinstallsMetadataChangesAndContainerTrees() throws {
        let path = try container()
        let installed = [app("Live")]
        XCTAssertFalse(PathGate.isSafeOrphanToTrash(path,
            installedApps: [app("Returned", id: "com.example.removed")], home: home))
        for blocked in [home + "/Library/Containers", path + "/Data",
                        try container("com.apple.protected"),
                        home + "/Library/Group Containers/group.com.example.removed"] {
            XCTAssertFalse(PathGate.isSafeOrphanToTrash(blocked, installedApps: installed, home: home), blocked)
        }
        _ = try container(appPaths: [root.appendingPathComponent("Returned.app").path])
        try fm.createDirectory(at: root.appendingPathComponent("Returned.app"), withIntermediateDirectories: true)
        XCTAssertFalse(PathGate.isSafeOrphanToTrash(path, installedApps: installed, home: home))
    }

    func testOrphanGateRejectsSymlinkedContainer() throws {
        let path = try container()
        let alias = home + "/Library/Containers/com.example.alias"
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: path)
        XCTAssertFalse(PathGate.isSafeOrphanToTrash(alias, installedApps: [app("Live")], home: home))
    }

    func testVerifiedContainerExecutesIntoIsolatedRecycleDirectory() async throws {
        let path = try container()
        try Data("fixture data".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("payload"))
        let destination = root.appendingPathComponent("isolated-recycle")
        let fixtureRoot = root!.path
        let executor = TrashExecutor(home: home) { source in
            guard source.path.hasPrefix(fixtureRoot + "/") else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        var item = CleanableItem(name: "Removed", path: path, bytes: 12, category: .orphans, isSelected: false, risk: .caution)
        item.isSelected = true
        let result = await executor.trash(items: [item], onProgress: { _ in })
        XCTAssertEqual(result.succeededPaths, [path])
        XCTAssertTrue(result.failedPaths.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("payload").path))
    }
}
