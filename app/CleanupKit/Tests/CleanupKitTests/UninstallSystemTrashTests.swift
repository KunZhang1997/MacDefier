import XCTest
import Darwin
@testable import CleanupKit

final class UninstallSystemTrashTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacDefier-SystemTrashTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func source() throws -> UninstallFileBoundary.Snapshot {
        let url = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return try UninstallFileBoundary.snapshot(url.path)
    }
    private func denied(_ source: UninstallFileBoundary.Snapshot) throws -> String {
        throw UninstallFileBoundary.Failure(code: "uninstall_permission_denied", path: source.path, errno: EACCES, operation: "rename")
    }

    func testOrdinaryMoveDoesNotRequestAuthorization() async throws {
        let item = try source()
        let path = try await UninstallSystemTrash.move(item, ordinaryMove: { _ in "ordinary" }, recycle: { _ in
            XCTFail("unnecessary authorization"); return ""
        })
        XCTAssertEqual(path, "ordinary")
    }
    func testProductionPermissionFailureNeverDelegatesToFinder() async throws {
        let item = try source()
        do {
            _ = try await UninstallSystemTrash.move(item, ordinaryMove: denied)
            XCTFail("Production must not use a pathname-based authorized fallback")
        } catch let failure as UninstallFileBoundary.Failure {
            XCTAssertEqual(failure.code, "uninstall_permission_denied")
            XCTAssertEqual(failure.errno, EACCES)
        }
        XCTAssertTrue(UninstallFileBoundary.stillMatches(item))
    }
    func testPermissionFailureContinuesAndVerifiesMovedIdentity() async throws {
        let item = try source()
        let dest = root.appendingPathComponent("fixture-trash.app").path
        let moved = try await UninstallSystemTrash.move(item, ordinaryMove: denied, recycle: { source in
            try FileManager.default.moveItem(atPath: source.path, toPath: dest)
            return dest
        })
        XCTAssertEqual(moved, dest)
        XCTAssertTrue(UninstallFileBoundary.isMissing(item.path))
    }
    func testAuthorizationCancellationPreservesSource() async throws {
        let item = try source()
        do {
            _ = try await UninstallSystemTrash.move(item, ordinaryMove: denied, recycle: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            })
            XCTFail("must cancel")
        } catch let failure as UninstallFileBoundary.Failure {
            XCTAssertEqual(failure.code, "uninstall_authorization_cancelled")
        }
        XCTAssertTrue(UninstallFileBoundary.stillMatches(item))
    }
    func testVerifiedReceiptDoesNotRequireListingDestinationDirectory() async throws {
        let item = try source()
        let trash = root.appendingPathComponent("execute-only-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let dest = trash.appendingPathComponent("Fixture.app").path
        defer { chmod(trash.path, 0o700) }
        let moved = try await UninstallSystemTrash.move(item, ordinaryMove: denied, recycle: { source in
            try FileManager.default.moveItem(atPath: source.path, toPath: dest)
            XCTAssertEqual(chmod(trash.path, 0o111), 0)
            return dest
        })
        XCTAssertEqual(moved, dest)
    }
    func testFinderDenialAndTimeoutHaveDistinctResults() {
        for (number, code) in [(-1743, "uninstall_finder_permission"), (-128, "uninstall_authorization_cancelled"),
                               (-1712, "uninstall_system_result_unknown")] {
            XCTAssertEqual(UninstallSystemTrash.classify(NSError(domain: NSOSStatusErrorDomain, code: number), path: "/fixture").code, code)
        }
    }
    func testChangedSourceNeverRequestsAuthorization() async throws {
        let item = try source()
        try FileManager.default.moveItem(atPath: item.path, toPath: root.appendingPathComponent("original.app").path)
        try FileManager.default.createDirectory(atPath: item.path, withIntermediateDirectories: false)
        do {
            _ = try await UninstallSystemTrash.move(item, ordinaryMove: denied, recycle: { _ in
                XCTFail("must not authorize replacement"); return ""
            })
            XCTFail("must reject")
        } catch let failure as UninstallFileBoundary.Failure { XCTAssertEqual(failure.code, "uninstall_identity_changed") }
    }
    func testUnsafeTrashAndReadOnlyFailuresDoNotRequestAuthorization() async throws {
        let item = try source()
        for code in ["uninstall_trash_unsafe", "uninstall_read_only", "uninstall_cross_volume", "uninstall_identity_changed"] {
            do {
                _ = try await UninstallSystemTrash.move(item, ordinaryMove: { _ in throw UninstallFileBoundary.Failure(code: code, path: item.path) }, recycle: { _ in
                    XCTFail("must not bypass \(code)"); return ""
                })
                XCTFail("must reject")
            } catch let failure as UninstallFileBoundary.Failure { XCTAssertEqual(failure.code, code) }
        }
    }
    func testMissingReceiptCannotReportSuccess() async throws {
        let item = try source()
        do {
            _ = try await UninstallSystemTrash.move(item, ordinaryMove: denied, recycle: { _ in "/nonexistent/receipt" })
            XCTFail("must verify receipt")
        } catch let failure as UninstallFileBoundary.Failure { XCTAssertEqual(failure.code, "uninstall_system_result_unknown") }
        XCTAssertTrue(UninstallFileBoundary.stillMatches(item))
    }
    func testSystemPermissionAndReadOnlyErrorsStayDistinct() {
        for (number, code) in [(EACCES, "uninstall_permission_denied"), (EPERM, "uninstall_operation_not_permitted"), (EROFS, "uninstall_read_only")] {
            let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(number))])
            XCTAssertEqual(UninstallSystemTrash.classify(error, path: "/fixture").code, code)
        }
    }
}
