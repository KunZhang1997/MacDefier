// PathIdentityTests — drives shipped CleanableItem.homeRelativePath / pathIdentityTitle.
// Run: cd app/CleanupKit && swift test --filter PathIdentityTests

import XCTest
@testable import CleanupKit

final class PathIdentityTests: XCTestCase {
    private var home: String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
    }

    private func item(path: String, name: String? = nil, category: CleanupCategory = .largeAppData) -> CleanableItem {
        let last = name ?? URL(fileURLWithPath: path).lastPathComponent
        return CleanableItem(
            name: last,
            path: path,
            bytes: 200 * 1024 * 1024,
            category: category,
            isSelected: true, // init still forces false — assert below
            risk: .caution
        )
    }

    func testHomeRelativePathDistinctForSiblingDownloads() {
        let a = home + "/projA/Downloads"
        let b = home + "/projB/Downloads"
        let ia = item(path: a)
        let ib = item(path: b)

        XCTAssertEqual(ia.homeRelativePath, "~/projA/Downloads")
        XCTAssertEqual(ib.homeRelativePath, "~/projB/Downloads")
        XCTAssertNotEqual(ia.homeRelativePath, ib.homeRelativePath)

        // Same last component, distinct identity titles
        XCTAssertEqual(ia.name, "Downloads")
        XCTAssertEqual(ib.name, "Downloads")
        XCTAssertEqual(ia.pathIdentityTitle, "projA/Downloads")
        XCTAssertEqual(ib.pathIdentityTitle, "projB/Downloads")
        XCTAssertNotEqual(ia.pathIdentityTitle, ib.pathIdentityTitle)
    }

    func testHomeRelativePathNestedDownloads() {
        let p = home + "/Downloads/installers/big.dmg"
        let i = item(path: p, name: "big.dmg")
        XCTAssertEqual(i.homeRelativePath, "~/Downloads/installers/big.dmg")
        XCTAssertEqual(i.pathIdentityTitle, "installers/big.dmg")
    }

    func testInitNeverAutoSelects() {
        let i = item(path: home + "/Caches/foo")
        XCTAssertFalse(i.isSelected, "display helpers must not enable selection")
    }

    func testOutsideHomeReturnsAbsolute() {
        let p = "/private/tmp/macdefier-path-identity-test"
        let i = item(path: p, name: "macdefier-path-identity-test")
        let rel = i.homeRelativePath
        XCTAssertFalse(rel.hasPrefix("~/"), rel)
        XCTAssertTrue(rel.contains("macdefier-path-identity-test"), rel)
    }
}
