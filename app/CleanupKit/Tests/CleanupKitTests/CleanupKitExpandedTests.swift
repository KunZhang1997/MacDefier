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

    func testAIHistorySkip() {
        let r = CleanupRiskPolicy.refine(
            name: "conversations-history",
            path: "/Users/x/.ollama/history",
            category: .aiApps,
            base: .caution
        )
        XCTAssertEqual(r, .skip)
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
    func testTrashPathDoesNotDeleteSymlinkTargetOutsideAllow() throws {
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

        let r = CliUninstallExecutor.trashPath(link.path, bytesHint: 0)
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
    func testTrashPathSymlinkMovesLinkNotTargetWhenBothUnderAllow() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("CLITrashSymOK-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let targetFile = base.appendingPathComponent("real-target.txt")
        try "stay".write(to: targetFile, atomically: true, encoding: .utf8)
        let link = base.appendingPathComponent("the-link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: targetFile.path)

        let r = CliUninstallExecutor.trashPath(link.path, bytesHint: 8)
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
    func testLoadSizeAfterRefreshDoesNotLeaveIsLoadingStuck() async {
        let service = SoftwareService()
        // Start a real refresh (may take a moment on this Mac)
        let started = expectation(description: "refresh started loading")
        service.refresh(force: true) {
            // completion may fire after cancel; ignore
        }
        // Spin until isLoading true or timeout
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if service.isLoading {
                started.fulfill()
                break
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !service.isLoading {
            // Refresh finished too fast — still verify cancel path recovers
            service.refresh(force: true)
            await Task.yield()
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)

        let dummy = InstalledApp(
            name: "Dummy",
            bundleIdentifier: "com.macdefier.test.dummy",
            path: "/Applications/Safari.app",
            version: "1",
            bytes: 0,
            isSystemLocation: true,
            canTrashAppBundle: false
        )
        // Cancels in-flight refresh + bumps generation
        service.loadSize(for: dummy)

        let clearDeadline = Date().addingTimeInterval(3)
        while Date() < clearDeadline {
            if !service.isLoading { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(service.isLoading, "isLoading must clear after generation bump from loadSize")

        // Subsequent refresh must be able to start (not permanently queued on stuck isLoading)
        var secondCompleted = false
        let secondDone = expectation(description: "second refresh completes")
        service.refresh(force: true) {
            secondCompleted = true
            secondDone.fulfill()
        }
        // If isLoading was stuck true without ownership, this would only queue and never run.
        // Give it time to complete a real inventory.
        await fulfillment(of: [secondDone], timeout: 60)
        XCTAssertTrue(secondCompleted)
        XCTAssertFalse(service.isLoading)
    }

    func testCancelInventoryWorkClearsIsLoading() async {
        let service = SoftwareService()
        service.refresh(force: true)
        service.cancelInventoryWork()
        XCTAssertFalse(service.isLoading)
        // Can start again
        let done = expectation(description: "after cancel")
        service.refresh(force: true) { done.fulfill() }
        await fulfillment(of: [done], timeout: 60)
        XCTAssertFalse(service.isLoading)
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
