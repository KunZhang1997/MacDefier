// Additional CleanupKit automated tests — Tests only, no product source edits.
// Run via: rsync to ~/Library/Caches/MacDefier-CleanupKit-test && swift test

import XCTest
@testable import CleanupKit

// MARK: - PathGate attack matrix (extra)

final class PathGateAttackMatrixTests: XCTestCase {
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func testMailMessagesMobileDocsBlockedOnAllGates() {
        let paths = [
            home + "/Library/Mail/V10/foo",
            home + "/Library/Messages/chat.db",
            home + "/Library/Mobile Documents/com~apple~CloudDocs/doc.txt"
        ]
        let target = "/Applications/Foo.app"
        for p in paths {
            XCTAssertTrue(PathGate.isSensitiveHardBlocked(p) || PathGate.isUninstallHardBlocked(p), p)
            XCTAssertFalse(PathGate.isSafeToTrash(p), "trash \(p)")
            XCTAssertFalse(PathGate.isSafeForUninstall(p, allowAppBundle: target), "uninstall \(p)")
            XCTAssertFalse(PathGate.isPathAllowedForScan(p), "scan \(p)")
        }
    }

    func testNeverDeleteExactRoots() {
        for p in ["/", home, home + "/Library", "/Applications", home + "/Documents"] {
            XCTAssertFalse(PathGate.isSafeToTrash(p), p)
        }
    }

    func testUserApplicationsOtherAppBlocked() {
        let target = home + "/Applications/Mine.app"
        let other = home + "/Applications/Other.app"
        XCTAssertTrue(PathGate.isSafeForUninstall(target, allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall(other, allowAppBundle: target))
    }

    func testLaunchAgentOnlyPlist() {
        let target = "/Applications/Foo.app"
        let root = home + "/Library/LaunchAgents"
        let ok = home + "/Library/LaunchAgents/com.foo.agent.plist"
        let bad = home + "/Library/LaunchAgents/com.foo.folder"
        XCTAssertFalse(PathGate.isSafeForUninstall(root, allowAppBundle: target), "root must be false")
        XCTAssertTrue(PathGate.isSafeForUninstall(ok, allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall(bad, allowAppBundle: target))
    }

    func testFilesInsideAllowAppBundleOK() {
        let target = "/Applications/Foo.app"
        let inner = "/Applications/Foo.app/Contents/MacOS/Foo"
        XCTAssertTrue(PathGate.isSafeForUninstall(inner, allowAppBundle: target))
    }

    func testChinesePhotosLibraryProtected() {
        let p = home + "/Pictures/照片图库.photoslibrary"
        XCTAssertTrue(ProtectedMediaRoots.contains(p))
        XCTAssertFalse(PathGate.isSafeToTrash(p))
    }

    func testTempDirAllowedForTrash() {
        let tmp = NSTemporaryDirectory() + "macdefier-test-\(UUID().uuidString).txt"
        XCTAssertTrue(PathGate.isSafeToTrash(tmp), tmp)
        XCTAssertTrue(PathGate.isPathAllowedForScan(tmp), tmp)
    }

    func testLMStudioCarveOut() {
        let p = home + "/.lmstudio/models/x"
        XCTAssertTrue(PathGate.isSafeToTrash(p))
        XCTAssertTrue(PathGate.isPathAllowedForScan(p))
    }

    /// 构造假 item：路径在敏感区时闸必须拒（不真正删除）
    func testForgedSensitiveItemWouldBeBlockedByGate() {
        let forged = [
            home + "/.ssh/authorized_keys",
            home + "/.aws/config",
            "/System/Library/CoreServices/Finder.app"
        ]
        for p in forged {
            XCTAssertFalse(PathGate.isSafeToTrash(p), p)
            XCTAssertFalse(PathGate.isSafeForUninstall(p, allowAppBundle: "/Applications/X.app"), p)
        }
    }
}

// MARK: - CleanupRiskPolicy

final class CleanupRiskPolicyTests: XCTestCase {
    private func item(
        name: String,
        path: String,
        category: CleanupCategory,
        risk: CleanupRisk
    ) -> CleanableItem {
        // isSelected param ignored by product (always false after scan)
        CleanableItem(
            name: name,
            path: path,
            bytes: 1024,
            category: category,
            isSelected: true,
            risk: risk
        )
    }

    func testNeverAutoSelectOnInit() {
        let i = CleanableItem(
            name: "foo",
            path: "/tmp/foo",
            bytes: 1,
            category: .temp,
            isSelected: true,
            risk: .safe
        )
        XCTAssertFalse(i.isSelected, "产品：扫描后一律不自动勾选")
    }

    func testAllCategoriesDefaultSelectedFalse() {
        for c in CleanupCategory.allCases {
            XCTAssertFalse(c.defaultSelected, c.rawValue)
        }
    }

    func testBrowserPasswordRefinesToSkip() {
        let r = CleanupRiskPolicy.refine(
            name: "Passwords",
            path: "/Users/x/Library/Application Support/Google/Chrome/Default/Login Data",
            category: .browsers,
            base: .caution
        )
        XCTAssertEqual(r, .skip)
    }

    func testBrowserCacheRefinesToRebuild() {
        let r = CleanupRiskPolicy.refine(
            name: "Cache",
            path: "/Users/x/Library/Caches/Google/Chrome",
            category: .browsers,
            base: .safe
        )
        XCTAssertEqual(r, .rebuild)
    }

    func testAIHistoryRefinesToCaution() {
        let r = CleanupRiskPolicy.refine(
            name: "conversations-history",
            path: "/Users/x/.ollama/history",
            category: .aiApps,
            base: .caution
        )
        XCTAssertEqual(r, .caution)
    }

    func testLowRiskBulkMatchesSafeAndRebuildWhileExcludingArchives() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let spotifyCache = CleanableItem(
            name: "com.spotify.client",
            path: home + "/Library/Caches/com.spotify.client",
            bytes: 1024,
            category: .userCache,
            isSelected: false,
            risk: .safe
        )
        let wallpaperItem = CleanableItem(
            name: "Aerial-1",
            path: home + "/Library/Application Support/com.apple.wallpaper/aerials/videos/1.mov",
            bytes: 2048,
            category: .wallpaper,
            isSelected: false,
            risk: .rebuild
        )
        let xcodeCache = CleanableItem(
            name: "com.apple.dt.Xcode",
            path: home + "/Library/Caches/com.apple.dt.Xcode",
            bytes: 4096,
            category: .xcode,
            isSelected: false,
            risk: .rebuild
        )
        let xcodeArchives = CleanableItem(
            name: "Archives",
            path: home + "/Library/Developer/Xcode/Archives",
            bytes: 8192,
            category: .xcode,
            isSelected: false,
            risk: .rebuild
        )
        XCTAssertTrue(CleanupRiskPolicy.isLowRiskBulkEligible(spotifyCache))
        XCTAssertTrue(CleanupRiskPolicy.isLowRiskBulkEligible(wallpaperItem))
        XCTAssertTrue(CleanupRiskPolicy.isLowRiskBulkEligible(xcodeCache))
        XCTAssertEqual(xcodeArchives.risk, .caution)
        XCTAssertFalse(CleanupRiskPolicy.isLowRiskBulkEligible(xcodeArchives))
    }

    func testOrphansAlwaysCaution() {
        let r = CleanupRiskPolicy.refine(
            name: "com.dead.app",
            path: "/Users/x/Library/Caches/com.dead.app",
            category: .orphans,
            base: .safe
        )
        XCTAssertEqual(r, .caution)
    }

    func testBaseSkipStaysSkip() {
        let r = CleanupRiskPolicy.refine(
            name: "anything",
            path: "/tmp/x",
            category: .userCache,
            base: .skip
        )
        XCTAssertEqual(r, .skip)
    }

    func testLowRiskBulkExcludesCautionSkipOrphansTrash() {
        let caution = item(
            name: "x",
            path: NSTemporaryDirectory() + "c",
            category: .userCache,
            risk: .caution
        )
        // item.risk may be refined again — if still caution, not bulk
        if caution.risk == .caution || caution.risk == .skip {
            XCTAssertFalse(CleanupRiskPolicy.isLowRiskBulkEligible(caution))
        }

        let eligibleXcode = CleanableItem(
            name: "DerivedData",
            path: FileManager.default.homeDirectoryForCurrentUser.path
                + "/Library/Developer/Xcode/DerivedData/Foo",
            bytes: 10,
            category: .xcode,
            isSelected: false,
            risk: .rebuild
        )
        // Only if refine left it rebuild/safe
        if eligibleXcode.risk == .rebuild || eligibleXcode.risk == .safe {
            XCTAssertTrue(CleanupRiskPolicy.isLowRiskBulkEligible(eligibleXcode))
        }

        let trash = CleanableItem(
            name: "old",
            path: FileManager.default.homeDirectoryForCurrentUser.path + "/.Trash/old",
            bytes: 1,
            category: .trash,
            isSelected: false,
            risk: .safe
        )
        XCTAssertFalse(CleanupRiskPolicy.isLowRiskBulkEligible(trash))
    }

    func testNeverListAppleOrphan() {
        XCTAssertTrue(CleanupRiskPolicy.shouldNeverListAsOrphan(
            name: "com.apple.Safari",
            path: "/Users/x/Library/Caches/com.apple.Safari"
        ))
        XCTAssertTrue(CleanupRiskPolicy.shouldNeverListAsOrphan(
            name: "com.macdefier.app",
            path: "/Users/x/Library/Caches/com.macdefier.app"
        ))
        XCTAssertTrue(CleanupRiskPolicy.shouldNeverListAsOrphan(
            name: "Homebrew",
            path: "/Users/x/Library/Caches/Homebrew"
        ))
    }

    func testBrowserDataKindPasswordsAreSkip() {
        XCTAssertEqual(BrowserDataKind.passwords.risk, .skip)
        XCTAssertEqual(BrowserDataKind.cache.risk, .rebuild)
    }
}

// MARK: - App inventory / query

final class AppInventoryPolicyTests: XCTestCase {
    func testNonRemovableIncludesSelfAndSafari() {
        XCTAssertTrue(AppInventory.nonRemovableBundleIDs.contains("com.macdefier.app"))
        XCTAssertTrue(AppInventory.nonRemovableBundleIDs.contains("com.apple.Safari"))
        XCTAssertTrue(AppInventory.nonRemovableBundleIDs.contains("com.apple.finder"))
    }

    func testFetchInstalledAppsReturnsAppsWithoutCrashing() {
        // Read-only inventory；不得崩溃。不依赖 apps.count >= 0 恒真断言。
        let apps = AppInventory.fetchInstalledApps(includeSystemApps: false, computeSize: false)
        // 策略：nonRemovable 与 canTrash 一致性（不依赖宿主是否装了 Safari）
        for app in apps where AppInventory.nonRemovableBundleIDs.contains(app.bundleIdentifier) {
            XCTAssertFalse(app.canTrashAppBundle, app.bundleIdentifier)
        }
        if let safari = apps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            XCTAssertFalse(safari.canTrashAppBundle)
        }
        if let selfApp = apps.first(where: {
            $0.bundleIdentifier == "com.macdefier.app" || $0.bundleIdentifier.hasPrefix("com.macdefier.")
        }) {
            XCTAssertFalse(selfApp.canTrashAppBundle)
        }
    }

    func testQueryMatcherDoesNotMatchEmptyOrSystemWords() {
        XCTAssertNil(AppQueryMatcher.extractQuery(from: "卸载"))
        XCTAssertNil(AppQueryMatcher.extractQuery(from: "删除缓存"))
        XCTAssertFalse(AppQueryMatcher.looksLikeTargetedUninstall("帮我看看空间"))
    }

    func testQueryMatcherWeChatAlias() {
        let apps = [
            InstalledApp(
                name: "WeChat",
                bundleIdentifier: "com.tencent.xinWeChat",
                path: "/Applications/WeChat.app",
                version: "1",
                bytes: 100,
                relatedBytes: 0,
                isSystemLocation: false,
                canTrashAppBundle: true
            ),
            InstalledApp(
                name: "Notes",
                bundleIdentifier: "com.apple.Notes",
                path: "/Applications/Notes.app",
                version: "1",
                bytes: 10,
                relatedBytes: 0,
                isSystemLocation: true,
                canTrashAppBundle: false
            )
        ]
        let hits = AppQueryMatcher.findMatches(query: "微信", in: apps)
        XCTAssertEqual(hits.first?.bundleIdentifier, "com.tencent.xinWeChat")
    }
}

// MARK: - Reuse TTL / software tier

final class PolicyUtilityTests: XCTestCase {
    func testReuseFreshness() {
        XCTAssertFalse(CleanupReusePolicy.isFresh(nil, ttl: 60))
        XCTAssertFalse(CleanupReusePolicy.isFresh(.distantPast, ttl: 60))
        XCTAssertTrue(CleanupReusePolicy.isFresh(Date(), ttl: 60))
        XCTAssertFalse(CleanupReusePolicy.isFresh(Date().addingTimeInterval(-120), ttl: 60))
        XCTAssertEqual(CleanupReusePolicy.cleanupTTL, 10 * 60)
        XCTAssertEqual(CleanupReusePolicy.softwareTTL, 15 * 60)
    }

    func testSoftwareSizeTiers() {
        let mb = UInt64(1_048_576)
        let gb = UInt64(1_073_741_824)
        XCTAssertEqual(SoftwareSizeTier.tier(for: 50 * mb), .light)
        XCTAssertEqual(SoftwareSizeTier.tier(for: 200 * mb), .medium)
        XCTAssertEqual(SoftwareSizeTier.tier(for: 2 * gb), .large)
        XCTAssertEqual(SoftwareSizeTier.tier(for: 12 * gb), .major)
        XCTAssertTrue(SoftwareSizeTier.major < SoftwareSizeTier.light)
    }
}

// MARK: - Protected media / AppData inventory roots

final class LocationsContractTests: XCTestCase {
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func testAppDataRootsAreInventoryNotTrash() {
        for root in AppDataLocations.allowedRoots {
            // Root itself under inventory
            XCTAssertTrue(AppDataLocations.isUnderAllowedRoot(root), root)
            // Media roots in AppData must not be trashable
            if ProtectedMediaRoots.contains(root) {
                XCTAssertFalse(PathGate.isSafeToTrash(root), root)
            }
        }
    }

    func testProtectedMediaListHasCNAndENPhotos() {
        let en = home + "/Pictures/Photos Library.photoslibrary"
        let cn = home + "/Pictures/照片图库.photoslibrary"
        XCTAssertTrue(ProtectedMediaRoots.list.contains(where: { $0 == en || PathGate.normalize($0) == PathGate.normalize(en) })
            || ProtectedMediaRoots.contains(en))
        XCTAssertTrue(ProtectedMediaRoots.contains(cn))
    }
}

// MARK: - TrashExecutor (only self-created temp files)

final class TrashExecutorSafePathTests: XCTestCase {
    func testOrphanExecutionBlocksDirectoryOwnedByReinstalledCursor() {
        let cursor = InstalledApp(
            name: "Cursor",
            bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            path: "/Applications/Cursor.app",
            version: "1",
            bytes: 0,
            isSystemLocation: false,
            canTrashAppBundle: true
        )

        XCTAssertTrue(
            TrashExecutor.shouldBlockOrphanPath(
                "/Users/test/Library/Application Support/Cursor",
                installedApps: [cursor]
            )
        )
        XCTAssertTrue(
            TrashExecutor.shouldBlockOrphanPath(
                "/Users/test/Library/Application Support/Cursor",
                installedApps: []
            ),
            "unverifiable installed-app inventory must fail closed"
        )
        XCTAssertTrue(
            TrashExecutor.shouldBlockOrphanPath(
                "/Users/test/Library/Application Support/DefinitelyUnownedProduct",
                installedApps: [cursor]
            )
        )
    }

    func testTrashBlockedPathReturnsErrorWithoutDeletingSensitive() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sensitive = home + "/.ssh/id_rsa_macdefier_test_does_not_need_exist"
        // Path may not exist → missing OR blocked; either way must not succeed cleanedCount for sensitive
        let item = CleanableItem(
            name: "fake-ssh",
            path: sensitive,
            bytes: 1,
            category: .userCache,
            isSelected: true,
            risk: .safe
        )
        // Product always forces isSelected=false in init — need selected true for trash
        // CleanableItem forces isSelected=false; TrashExecutor filters isSelected
        // So we must use a mutated copy if possible — Hashable struct with var isSelected
        var selectable = item
        selectable.isSelected = true
        XCTAssertTrue(selectable.isSelected)

        let exec = TrashExecutor()
        let result = await exec.trash(items: [selectable]) { _ in }
        // Should not free sensitive path successfully
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertTrue(result.trashedPaths.isEmpty)
        // errors: missing or blocked
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testTrashSelfCreatedTempFileSucceeds() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("MDTrashTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("junk.txt")
        try "hello-macdefier-test".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        XCTAssertTrue(PathGate.isSafeToTrash(file.path))

        var item = CleanableItem(
            name: "junk.txt",
            path: file.path,
            bytes: 20,
            category: .temp,
            isSelected: true,
            risk: .rebuild
        )
        item.isSelected = true

        let exec = TrashExecutor()
        let result = await exec.trash(items: [item]) { _ in }
        XCTAssertEqual(result.cleanedCount, 1, result.errors.joined(separator: "; "))
        XCTAssertFalse(fm.fileExists(atPath: file.path), "file should be moved to Trash")
        XCTAssertEqual(result.freedBytes, 0, "moving to Trash does not free disk space")
        XCTAssertEqual(result.movedToTrashBytes, 20)
        // cleanup: remove empty dir if left
        try? fm.removeItem(at: dir)
    }

    func testTrashUnselectedDoesNothing() async throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("MDTrashSkip-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: file) }

        let item = CleanableItem(
            name: "skip",
            path: file.path,
            bytes: 1,
            category: .temp,
            isSelected: false,
            risk: .safe
        )
        // init forces false already
        XCTAssertFalse(item.isSelected)

        let exec = TrashExecutor()
        let result = await exec.trash(items: [item]) { _ in }
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }
}

// MARK: - CLI trashPath symlink + npm resolve

final class CliUninstallSafetyTests: XCTestCase {
    /// Soft link under allow tree pointing outside allow: target entity must survive; link trashed or blocked.
    func testTrashPathDoesNotDeleteSymlinkTargetOutsideAllow() async throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let base = fm.temporaryDirectory.appendingPathComponent("CLITrashSym-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        // Target under home (not junk allow) — must not be deleted if gate resolves through the link
        let outsideDir = URL(fileURLWithPath: home).appendingPathComponent("MacDefier_CLITrash_keep_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: base)
            try? fm.removeItem(at: outsideDir)
        }

        let targetFile = outsideDir.appendingPathComponent("keep-me.txt")
        try "precious".write(to: targetFile, atomically: true, encoding: .utf8)
        XCTAssertFalse(PathGate.isSafeToTrash(targetFile.path), "fixture: outside target must not be trash-allowed")

        // Symlink lives under NSTemporaryDirectory allow tree
        let link = base.appendingPathComponent("link-to-outside")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: targetFile.path)

        let r = await CliUninstallExecutor.trashPath(link.path, bytesHint: 0)
        // Target entity must still exist regardless of link outcome
        XCTAssertTrue(fm.fileExists(atPath: targetFile.path), "out-of-tree target must not be deleted")
        XCTAssertEqual(try String(contentsOf: targetFile, encoding: .utf8), "precious")
        // Resolved path fails PathGate → blocked (preferred); never success-trash of the target
        XCTAssertFalse(r.errors.isEmpty || r.trashed.contains(targetFile.path),
                       "must not report target path as trashed")
        if r.errors.isEmpty {
            // If implementation trashes the link only, target still present (asserted above)
            XCTAssertFalse(r.trashed.contains(where: { PathGate.normalize($0) == PathGate.normalize(targetFile.path) }))
        } else {
            XCTAssertTrue(r.errors.contains(where: { $0.contains("blocked") }), r.errors.joined(separator: "; "))
        }
    }

    /// Soft link under temp → another temp file: trash original link, target entity remains.
    func testTrashPathSymlinkMovesLinkNotTargetWhenBothUnderAllow() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("CLITrashSymOK-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let targetFile = base.appendingPathComponent("real-target.txt")
        try "stay".write(to: targetFile, atomically: true, encoding: .utf8)
        let link = base.appendingPathComponent("the-link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: targetFile.path)

        let r = await CliUninstallExecutor.trashPath(link.path, bytesHint: 8)
        XCTAssertTrue(r.errors.isEmpty, r.errors.joined(separator: "; "))
        XCTAssertTrue(fm.fileExists(atPath: targetFile.path), "target entity must remain")
        XCTAssertEqual(try String(contentsOf: targetFile, encoding: .utf8), "stay")
        // Original link path should be gone (moved to Trash)
        let linkExists = fm.fileExists(atPath: link.path)
        XCTAssertFalse(linkExists, "symlink itself should be trashed, not left in place")
    }

    func testResolveNpmBinaryDoesNotHardPinNode22Only() async {
        // Must not invent a non-executable node@22 path as the sole answer when missing
        let resolved = await CliUninstallExecutor.resolveNpmBinary(preferHomebrew: true)
        if let resolved {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved), resolved)
            XCTAssertFalse(resolved.isEmpty)
        }
        // Contract: absent keg must not be the sole invented answer
        let pinned = "/opt/homebrew/opt/node@22/bin/npm"
        if !FileManager.default.isExecutableFile(atPath: pinned) {
            XCTAssertNotEqual(resolved, pinned)
        }
    }
}

// MARK: - SoftwareService isLoading generation recovery

@MainActor
final class SoftwareServiceLoadingTests: XCTestCase {
    private final class InventoryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                let ready = opened
                if !ready { waiters.append(continuation) }
                lock.unlock()
                if ready { continuation.resume() }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    private func fixture(_ name: String) -> InstalledApp {
        InstalledApp(name: name, bundleIdentifier: "invalid.loading-fixture.\(name)",
                     path: "/not-a-real-volume/LoadingFixture/\(name).app", version: "1",
                     bytes: 0, isSystemLocation: false, canTrashAppBundle: false,
                     sizeState: .pending)
    }

    func testLoadSizeAfterRefreshDoesNotLeaveIsLoadingStuck() async {
        let service = SoftwareService()
        let gate = InventoryGate()
        defer { service.cancelInventoryWork(); gate.open() }
        let app = fixture("Metadata")
        let started = expectation(description: "refresh started loading")
        let done = expectation(description: "metadata completed")
        service.testInventoryHandler = {
            started.fulfill()
            await gate.wait()
            XCTAssertFalse(Task.isCancelled, "A size request must not cancel metadata enumeration")
            return [app]
        }
        service.testSizeHandler = { _ in nil }
        service.refresh(force: true) { done.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(service.isLoading)
        service.resumeSizeCalculation()
        XCTAssertTrue(service.isLoading, "Metadata retains ownership of its loading state")
        gate.open()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.apps.map(\.path), [app.path])

        // A later refresh can still acquire and release the loading state.
        service.testInventoryHandler = { [app] }
        let secondDone = expectation(description: "second refresh completes")
        service.refresh(force: true) { secondDone.fulfill() }
        await fulfillment(of: [secondDone], timeout: 3)
        XCTAssertFalse(service.isLoading)
    }

    func testCancelInventoryWorkClearsIsLoading() async {
        let service = SoftwareService()
        let gate = InventoryGate()
        defer { service.cancelInventoryWork(); gate.open() }
        let oldApp = fixture("Old")
        let newApp = fixture("New")
        let started = expectation(description: "old inventory started")
        let oldDone = expectation(description: "cancelled inventory returned")
        service.testInventoryHandler = {
            started.fulfill()
            await gate.wait() // Ignore cancellation so late-result protection is exercised.
            return [oldApp]
        }
        service.testSizeHandler = { _ in nil }
        service.refresh(force: true) { oldDone.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(service.isLoading)
        service.cancelInventoryWork()
        XCTAssertFalse(service.isLoading)

        service.testInventoryHandler = { [newApp] }
        let done = expectation(description: "after cancel")
        service.refresh(force: true) { done.fulfill() }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.apps.map(\.path), [newApp.path])
        gate.open()
        await fulfillment(of: [oldDone], timeout: 3)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.apps.map(\.path), [newApp.path], "Cancelled metadata must not replace the newer list")
    }
}

// MARK: - UninstallExecutor gate via public trash (forged wrong app — no real delete)

final class UninstallExecutorGateTests: XCTestCase {
    func testUninstallRefusesOtherAppBundleEvenIfSelected() async throws {
        // Use non-existent victim path under Applications — must block, not permission-prompt forever
        let victim = "/Applications/MacDefier_QA_Victim_DoesNotExist_\(UUID().uuidString).app"
        let allow = "/Applications/MacDefier_QA_Target_DoesNotExist.app"
        var item = CleanableItem(
            name: "Victim",
            path: victim,
            bytes: 1,
            category: .userCache,
            isSelected: true,
            risk: .rebuild
        )
        item.isSelected = true

        let result = await UninstallExecutor.shared.trash(items: [item], appBundlePath: allow)
        XCTAssertEqual(result.cleanedCount, 0)
        // blocked or missing — never cleaned
        XCTAssertTrue(result.trashedPaths.isEmpty)
        XCTAssertFalse(result.errors.isEmpty)
    }

    // MARK: - F1 TrashExecutor TOCTOU identity verification

    func testTrashExecutorExecutionWindowIdentityGuard() async throws {
        let fm = FileManager.default
        let fixtureRoot = fm.temporaryDirectory.appendingPathComponent("F1-TOCTOU-\(UUID().uuidString)", isDirectory: true)
        let home = fixtureRoot.appendingPathComponent("Home", isDirectory: true).path
        let recycleSink = fixtureRoot.appendingPathComponent("Recycled", isDirectory: true)
        let externalDir = fixtureRoot.appendingPathComponent("ExternalImportant", isDirectory: true)
        try fm.createDirectory(atPath: home + "/Library/Caches/TargetSub", withIntermediateDirectories: true)
        try fm.createDirectory(at: recycleSink, withIntermediateDirectories: true)
        try fm.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixtureRoot) }

        let idleBrowser = BrowserCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .idle })
        let idleAI = AIToolCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .idle })

        // Case 1: Leaf file replaced with a new inode during the occupancy check window -> REJECTED.
        let leafPath = home + "/Library/Caches/TargetSub/leaf.dat"
        try Data("original-cache-bytes".utf8).write(to: URL(fileURLWithPath: leafPath))
        let replacementPayload = Data("newly-swapped-important-file".utf8)

        let swapLeafExecutor = TrashExecutor(
            home: home,
            browserCleanupGuard: idleBrowser,
            aiToolCleanupGuard: idleAI,
            occupancyGuard: { checkedPath in
                // Simulate external race replacing leaf inode during slow lsof/ps check.
                try? fm.removeItem(atPath: checkedPath)
                try? replacementPayload.write(to: URL(fileURLWithPath: checkedPath))
                return nil
            },
            recycle: { url in
                XCTFail("Must never recycle swapped inode: \(url.path)")
            }
        )
        var leafItem = CleanableItem(name: "leaf.dat", path: leafPath, bytes: 20, category: .userCache, isSelected: false)
        leafItem.isSelected = true
        let swapLeafResult = await swapLeafExecutor.trash(items: [leafItem], onProgress: { _ in })
        XCTAssertEqual(swapLeafResult.cleanedCount, 0)
        XCTAssertEqual(swapLeafResult.changedPaths, [leafPath])
        XCTAssertEqual(swapLeafResult.failures.map(\.kind), [.changed])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: leafPath)), replacementPayload)

        // Case 2: Parent directory replaced with a symlink to external victim directory during occupancy check -> REJECTED.
        let victimFile = externalDir.appendingPathComponent("victim.dat")
        let victimPayload = Data("do-not-delete-external-victim".utf8)
        try victimPayload.write(to: victimFile)

        let subDir = home + "/Library/Caches/ParentSwapSub"
        try fm.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        let subTarget = subDir + "/victim.dat"
        try Data("harmless-cache".utf8).write(to: URL(fileURLWithPath: subTarget))

        let swapParentExecutor = TrashExecutor(
            home: home,
            browserCleanupGuard: idleBrowser,
            aiToolCleanupGuard: idleAI,
            occupancyGuard: { _ in
                // Replace parent directory with symlink pointing at externalDir!
                try? fm.removeItem(atPath: subDir)
                try? fm.createSymbolicLink(atPath: subDir, withDestinationPath: externalDir.path)
                return nil
            },
            recycle: { url in
                XCTFail("Must never recycle through swapped parent symlink: \(url.path)")
            }
        )
        var parentSwapItem = CleanableItem(name: "victim.dat", path: subTarget, bytes: 14, category: .userCache, isSelected: false)
        parentSwapItem.isSelected = true
        let swapParentResult = await swapParentExecutor.trash(items: [parentSwapItem], onProgress: { _ in })
        XCTAssertEqual(swapParentResult.cleanedCount, 0)
        XCTAssertEqual(swapParentResult.changedPaths, [subTarget])
        XCTAssertEqual(swapParentResult.failures.map(\.kind), [.changed])
        XCTAssertEqual(try Data(contentsOf: victimFile), victimPayload)

        // Case 3: Positive control — unchanged file passes identity re-verification and recycles normally.
        let untouchedPath = home + "/Library/Caches/TargetSub/untouched.dat"
        try Data("cleanable-bytes".utf8).write(to: URL(fileURLWithPath: untouchedPath))
        let okExecutor = TrashExecutor(
            home: home,
            browserCleanupGuard: idleBrowser,
            aiToolCleanupGuard: idleAI,
            occupancyGuard: { _ in nil },
            recycle: { url in
                try fm.moveItem(at: url, to: recycleSink.appendingPathComponent(url.lastPathComponent))
            }
        )
        var okItem = CleanableItem(name: "untouched.dat", path: untouchedPath, bytes: 15, category: .userCache, isSelected: false)
        okItem.isSelected = true
        let okResult = await okExecutor.trash(items: [okItem], onProgress: { _ in })
        XCTAssertEqual(okResult.cleanedCount, 1)
        XCTAssertTrue(okResult.changedPaths.isEmpty)
        XCTAssertEqual(okResult.succeededPaths, [untouchedPath])
        XCTAssertFalse(fm.fileExists(atPath: untouchedPath))
        XCTAssertTrue(fm.fileExists(atPath: recycleSink.appendingPathComponent("untouched.dat").path))
    }

    func testInstalledAppFormattedSizeDetailSupportsEnglishAndChinese() {
        let app = InstalledApp(
            name: "Demo",
            bundleIdentifier: "com.example.demo",
            path: "/Applications/Demo.app",
            version: "1.0",
            bytes: 200_000_000,
            relatedBytes: 100 * 1_048_576,
            isSystemLocation: false,
            canTrashAppBundle: true
        )
        let en = app.formattedSizeDetail(english: true)
        let zh = app.formattedSizeDetail(english: false)
        XCTAssertEqual(en?.hasPrefix("App "), true)
        XCTAssertEqual(en?.contains(" · Data "), true)
        XCTAssertEqual(zh?.hasPrefix("应用 "), true)
        XCTAssertEqual(zh?.contains(" · 数据 "), true)
    }
}

// MARK: - MatchingString extras

final class MatchingStringExtraTests: XCTestCase {
    func testStripTrailingVersion() {
        XCTAssertEqual("Foo 1.2.3".mdStrippingTrailingVersion(), "Foo")
        XCTAssertEqual("Bar".mdStrippingTrailingVersion(), "Bar")
    }

    func testBundleLastTwoComponents() {
        XCTAssertEqual("com.tencent.xinWeChat".mdBundleLastTwoComponents, "tencentxinwechat")
    }

    func testBaseBundleIdentifierHelper() {
        XCTAssertEqual("com.foo.bar.helper".mdBaseBundleIdentifier, "com.foo.bar")
        XCTAssertNil("com.foo.bar".mdBaseBundleIdentifier)
    }

    func testPasswordStopwordPresent() {
        XCTAssertTrue(MatchingSegments.stopwords.contains("password"))
        XCTAssertTrue(MatchingSegments.stopwords.contains("passwords"))
    }
}
