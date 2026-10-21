// Preview = execute path consistency (Batch 4).
// Run: cd app/CleanupKit && swift test --filter PreviewExecuteConsistency

import XCTest
@testable import CleanupKit

final class PreviewExecuteConsistencyTests: XCTestCase {
    private var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    func testCookieSpecsNotInCatalogExecutableList() {
        let specs = BrowserCleanupCatalog.specs(home: home, fm: .default)
        XCTAssertFalse(specs.contains { $0.kind == .cookies }, "Cookie must not enter cleanup list")
        XCTAssertFalse(specs.contains { $0.kind == .passwords }, "Password stores must not be selectable list items")
    }

    func testBrowserCredentialPathsNeverSafeToTrash() {
        let paths = [
            home + "/Library/Application Support/Google/Chrome/Default/Cookies",
            home + "/Library/Application Support/Google/Chrome/Default/Login Data",
            home + "/Library/Cookies/Cookies.binarycookies"
        ]
        for p in paths {
            XCTAssertFalse(PathGate.isSafeToTrash(p), p)
        }
    }

    func testColimaInventoryRootNotSafeToTrash() {
        let colima = home + "/.colima/default/rootfs"
        XCTAssertTrue(AppDataLocations.isUnderAllowedRoot(colima) || AppDataLocations.isUnderAllowedRoot(home + "/.colima"))
        XCTAssertFalse(PathGate.isSafeToTrash(colima))
    }

    func testMultiPathItemAllPathsVisible() {
        let primary = home + "/Library/Caches/com.example.a"
        let extras = [
            home + "/Library/Caches/com.example.b",
            home + "/Library/Caches/com.example.c",
            home + "/Library/Caches/com.example.d"
        ]
        let item = CleanableItem(
            name: "multi",
            path: primary,
            bytes: 100,
            category: .userCache,
            isSelected: false,
            extraPaths: extras
        )
        XCTAssertEqual(item.allPaths.count, 4, "extraPaths=3 → preview must expose 4 paths")
    }

    @MainActor
    func testConfirmGatesOutBlockedPaths() async {
        let service = CleanupService()
        let tmp = NSTemporaryDirectory() + "preview-exec-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let ok = tmp + "/ok.cache"
        try? "x".write(toFile: ok, atomically: true, encoding: .utf8)
        let blocked = home + "/.ssh/id_rsa"

        service.testScanHandler = { _ in
            let item = CleanableItem(
                name: "mix",
                path: ok,
                bytes: 1,
                category: .userCache,
                isSelected: false,
                risk: .rebuild,
                extraPaths: [blocked]
            )
            return [CleanupCategoryGroup(category: .userCache, items: [item])]
        }
        let done = expectation(description: "scan")
        _ = service.startScan(force: true) { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        service.setSelected(itemID: service.allItems[0].id, selected: true)

        let execPaths = service.selectedExecutablePaths
        XCTAssertTrue(execPaths.contains(where: { $0.hasSuffix("ok.cache") || $0 == ok }))
        XCTAssertFalse(execPaths.contains(where: { $0.contains(".ssh") }), "blocked path must not enter executor set")
    }
}
