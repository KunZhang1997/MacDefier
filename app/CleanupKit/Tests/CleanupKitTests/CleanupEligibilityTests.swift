import XCTest
@testable import CleanupKit

final class CleanupEligibilityTests: XCTestCase {
    func testGenericGoogleParentCannotBypassRunningBrowserAtPreview() {
        let browser = BrowserCleanupGuard(processState: { _ in .inUse }, openFileState: { _ in .idle })
        XCTAssertEqual(CleanupEligibility.previewBlock(for: "/Users/fixture/Library/Caches/Google", home: "/Users/fixture", browser: browser, canMove: { _ in true }), .inUse)
    }
    func testPermissionPreflightAndUnknownBrowserAreNotSelectableWork() {
        let idle = BrowserCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .idle })
        XCTAssertEqual(CleanupEligibility.previewBlock(for: "/private/var/log/install.log", home: "/Users/fixture", browser: idle, canMove: { _ in false }), .permissionDenied)
        let unknown = BrowserCleanupGuard(processState: { _ in .unknown }, openFileState: { _ in .idle })
        XCTAssertEqual(CleanupEligibility.previewBlock(for: "/Users/fixture/Library/Caches/Google", home: "/Users/fixture", browser: unknown, canMove: { _ in true }), .protectedResource)
    }
    func testPermissionClassificationUsesCodesInsteadOfLocalizedErrorText() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let outer = NSError(domain: "Fixture", code: 1, userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertEqual(CleanupEligibility.classify(outer), .permissionDenied)
        XCTAssertEqual(CleanupEligibility.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)), .permissionDenied)
        XCTAssertEqual(CleanupEligibility.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), .missing)
        XCTAssertEqual(CleanupEligibility.classify(NSError(domain: "Fixture", code: 513)), .unknown)
    }
    func testParentPermissionPreflightUsesRealTemporaryFixture() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacDefier-permission-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("log.txt")
        try Data("fixture".utf8).write(to: file)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? fm.removeItem(at: root) }
        XCTAssertTrue(CleanupEligibility.canMoveToTrash(file.path))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertFalse(CleanupEligibility.canMoveToTrash(file.path))
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }
}
