import Darwin
import Foundation
import XCTest
@testable import CleanupKit

/// All filesystem operations are confined to fresh UUID fixtures. The real
/// user's Trash, application bundles, and protected system paths are never used.
final class UninstallBoundaryErrorTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("UninstallBoundaryErrors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func file(_ name: String, in root: URL, contents: String = "keep") throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func assertFailure(_ error: Error, code: String, errno errorNumber: Int32?,
                               operation: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard let failure = error as? UninstallFileBoundary.Failure else {
            return XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
        XCTAssertEqual(failure.code, code, file: file, line: line)
        XCTAssertEqual(failure.errno, errorNumber, file: file, line: line)
        if let operation { XCTAssertEqual(failure.operation, operation, file: file, line: line) }
    }

    func testPOSIXFailuresRetainDistinctReasonErrnoAndOperation() {
        let cases: [(Int32, String)] = [
            (EACCES, "uninstall_permission_denied"),
            (EPERM, "uninstall_operation_not_permitted"),
            (EROFS, "uninstall_read_only"),
            (EXDEV, "uninstall_cross_volume"),
            (ENOENT, "uninstall_missing"),
            (EBUSY, "uninstall_locked"),
            (ETXTBSY, "uninstall_locked"),
            (ENOSPC, "uninstall_disk_full"),
            (EDQUOT, "uninstall_disk_full"),
            (EIO, "uninstall_boundary_failed")
        ]
        for (errorNumber, expected) in cases {
            let failure = UninstallFileBoundary.posixFailure("/fixture-only/item", errno: errorNumber,
                                                             operation: "renameatx_np")
            assertFailure(failure, code: expected, errno: errorNumber, operation: "renameatx_np")
            XCTAssertEqual(failure.localizedDescription, expected + ":/fixture-only/item")
        }
        let legacy = UninstallFileBoundary.Failure(code: "uninstall_identity_changed", path: "/fixture-only/item")
        XCTAssertNil(legacy.errno)
        XCTAssertNil(legacy.operation)
    }

    func testMissingSnapshotReportsMissingInsteadOfIdentityChange() throws {
        let root = try fixture()
        XCTAssertThrowsError(try UninstallFileBoundary.snapshot(root.appendingPathComponent("missing").path)) {
            self.assertFailure($0, code: "uninstall_missing", errno: ENOENT, operation: "snapshot.item_stat")
        }
    }

    func testMissingAfterSnapshotPreservesReasonThroughValidationAndMove() throws {
        let root = try fixture()
        let source = try file("source", in: root)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        let retained = root.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: source, to: retained)
        XCTAssertThrowsError(try UninstallFileBoundary.validate(snapshot)) {
            self.assertFailure($0, code: "uninstall_missing", errno: ENOENT, operation: "snapshot.item_stat")
        }
        XCTAssertFalse(UninstallFileBoundary.stillMatches(snapshot))
        let destination = root.appendingPathComponent("unused-destination")
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: destination.path)) {
            self.assertFailure($0, code: "uninstall_missing", errno: ENOENT, operation: "snapshot.item_stat")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "keep")
    }

    func testUnreadableParentRemainsPermissionFailureDuringValidationAndMove() throws {
        try XCTSkipIf(geteuid() == 0, "Permission denial requires an unprivileged test process")
        let root = try fixture()
        let parent = try folder("parent", in: root)
        let destination = try folder("destination", in: root)
        let source = try file("source", in: parent)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        XCTAssertThrowsError(try UninstallFileBoundary.validate(snapshot)) {
            self.assertFailure($0, code: "uninstall_permission_denied", errno: EACCES)
        }
        XCTAssertFalse(UninstallFileBoundary.stillMatches(snapshot))
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: destination.path)) {
            self.assertFailure($0, code: "uninstall_permission_denied", errno: EACCES)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep")
    }

    func testUnreadableDestinationIsNotMisreportedAsUnsafeTrash() throws {
        try XCTSkipIf(geteuid() == 0, "Permission denial requires an unprivileged test process")
        let root = try fixture()
        let destination = try folder("destination", in: root)
        let source = try file("source", in: root)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destination.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path) }
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: destination.path)) {
            self.assertFailure($0, code: "uninstall_permission_denied", errno: EACCES,
                               operation: "open_directory.component")
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testRenamePermissionFailureRetainsItsOperationAndKeepsSource() throws {
        try XCTSkipIf(geteuid() == 0, "Permission denial requires an unprivileged test process")
        let root = try fixture()
        let parent = try folder("parent", in: root)
        let destination = try folder("destination", in: root)
        let source = try file("source", in: parent)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        XCTAssertNoThrow(try UninstallFileBoundary.validate(snapshot))
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: destination.path)) {
            self.assertFailure($0, code: "uninstall_permission_denied", errno: EACCES, operation: "renameatx_np")
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testActualReplacementStillReportsIdentityChange() throws {
        let root = try fixture()
        let destination = try folder("destination", in: root)
        let source = try file("source", in: root)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("retained-original"))
        _ = try file("source", in: root, contents: "replacement")
        XCTAssertThrowsError(try UninstallFileBoundary.validate(snapshot)) {
            self.assertFailure($0, code: "uninstall_identity_changed", errno: nil, operation: "validate.identity")
        }
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: destination.path)) {
            self.assertFailure($0, code: "uninstall_identity_changed", errno: nil)
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testSymlinkDestinationStillFailsClosed() throws {
        let root = try fixture()
        let destination = try folder("destination", in: root)
        let link = root.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let source = try file("source", in: root)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: link.path)) { error in
            let failure = error as? UninstallFileBoundary.Failure
            XCTAssertEqual(failure?.code, "uninstall_trash_unsafe")
            XCTAssertTrue(failure?.errno == ENOTDIR || failure?.errno == ELOOP)
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testWritableByOthersDestinationStillFailsClosed() throws {
        let root = try fixture()
        let destination = try folder("destination", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: destination.path)
        let source = try file("source", in: root)
        XCTAssertThrowsError(try UninstallFileBoundary.move(UninstallFileBoundary.snapshot(source.path),
                                                           toTrashDirectory: destination.path)) {
            self.assertFailure($0, code: "uninstall_trash_unsafe", errno: nil)
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testFoundationWrappedPOSIXFailureKeepsUnderlyingReason() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        let failure = UninstallFileBoundary.fileSystemFailure(wrapped, path: "/fixture-only/item",
                                                              operation: "trash_directory_lookup")
        assertFailure(failure, code: "uninstall_operation_not_permitted", errno: EPERM,
                      operation: "trash_directory_lookup")
    }

    func testCocoaOnlyFailuresDoNotInventPOSIXErrno() {
        let cases = [
            (NSFileReadNoPermissionError, "uninstall_permission_denied"),
            (NSFileWriteNoPermissionError, "uninstall_permission_denied"),
            (NSFileReadNoSuchFileError, "uninstall_missing"),
            (NSFileNoSuchFileError, "uninstall_missing"),
            (NSFileWriteVolumeReadOnlyError, "uninstall_read_only"),
            (NSFileWriteOutOfSpaceError, "uninstall_disk_full")
        ]
        for (code, expected) in cases {
            let failure = UninstallFileBoundary.fileSystemFailure(NSError(domain: NSCocoaErrorDomain, code: code),
                                                                  path: "/fixture-only/item", operation: "trash_directory_lookup")
            assertFailure(failure, code: expected, errno: nil, operation: "trash_directory_lookup")
        }
    }
}
