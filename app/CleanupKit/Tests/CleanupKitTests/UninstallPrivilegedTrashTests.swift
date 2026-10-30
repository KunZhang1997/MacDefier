import Darwin
import Foundation
import UninstallHelperCore
import XCTest
@testable import CleanupKit

/// Exercises only rejection classification with synthetic helper replies. No
/// authorization, service connection, Trash move or real app path is used.
final class UninstallPrivilegedTrashTests: XCTestCase {
    private let fm = FileManager.default

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/MacDefier-PrivilegedError-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func rejected(_ source: URL, reason: String? = "helper_directory_open_failed",
                          errorNumber: Int32?) -> UninstallFileBoundary.Failure {
        let result = UninstallResult(disposition: .rejected, requestID: UUID(), sourcePath: source.path,
                                     reason: reason, errno: errorNumber)
        return UninstallPrivilegedTrash.rejected(result, source: source.path)
    }

    func testMetadataReasonIsPreservedWhenHelperAlsoReturnsErrno() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("Wrapped.app")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        // This app intentionally has no Contents directory, matching a wrapped
        // layout without opening or modifying an installed application.
        for (reason, expected, number) in [
            ("helper_application_metadata_unavailable", "uninstall_application_metadata_unavailable", ENOENT),
            ("helper_application_metadata_unavailable", "uninstall_application_metadata_unavailable", EACCES),
            ("helper_application_metadata_invalid", "uninstall_application_metadata_invalid", EINVAL)
        ] {
            let failure = rejected(source, reason: reason, errorNumber: number)
            XCTAssertEqual(failure.code, expected)
            XCTAssertEqual(failure.path, source.path)
            XCTAssertEqual(failure.errno, number)
            XCTAssertEqual(failure.operation, "privileged_trash")
        }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testENOENTForInternalPathDoesNotClaimExistingAppIsMissing() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("Present.app")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let failure = rejected(source, errorNumber: ENOENT)
        XCTAssertEqual(failure.code, "uninstall_helper_safety_refused")
        XCTAssertEqual(failure.errno, ENOENT)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testENOENTReportsMissingOnlyWhenSourceIsConfirmedAbsent() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("Missing.app")
        let failure = rejected(source, errorNumber: ENOENT)
        XCTAssertEqual(failure.code, "uninstall_missing")
        XCTAssertEqual(failure.path, source.path)
        XCTAssertEqual(failure.errno, ENOENT)
        XCTAssertEqual(failure.operation, "privileged_trash")
    }

    func testDanglingSourceSymlinkDoesNotCountAsMissing() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: source, withDestinationURL: root.appendingPathComponent("missing-target"))
        XCTAssertEqual(rejected(source, errorNumber: ENOENT).code, "uninstall_helper_safety_refused")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: source.path), root.appendingPathComponent("missing-target").path)
    }

    func testUnreadableSourceDoesNotCountAsMissing() throws {
        try XCTSkipIf(geteuid() == 0, "Permission fixture requires an unprivileged process")
        let root = try fixture()
        let parent = root.appendingPathComponent("restricted")
        let source = parent.appendingPathComponent("Present.app")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0), 0)
        defer { _ = chmod(parent.path, 0o700) }
        XCTAssertEqual(rejected(source, errorNumber: ENOENT).code, "uninstall_helper_safety_refused")
    }

    func testScopeAndIdentityReasonsTakePriorityOverErrno() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("Missing.app")
        for (reason, expected) in [
            ("helper_source_identity_changed", "uninstall_identity_changed"),
            ("helper_source_parent_changed", "uninstall_identity_changed"),
            ("helper_staged_identity_changed", "uninstall_identity_changed"),
            ("helper_protected_application", "uninstall_helper_scope_rejected"),
            ("helper_source_path_rejected", "uninstall_helper_scope_rejected"),
            ("helper_cross_volume", "uninstall_cross_volume")
        ] {
            for number in [ENOENT, EACCES] {
                let failure = rejected(source, reason: reason, errorNumber: number)
                XCTAssertEqual(failure.code, expected, reason)
                XCTAssertEqual(failure.errno, number)
            }
        }
    }

    func testOtherPOSIXErrorsKeepTheirPreciseClassification() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("Present.app")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for (number, expected) in [
            (EACCES, "uninstall_permission_denied"), (EPERM, "uninstall_operation_not_permitted"),
            (EROFS, "uninstall_read_only"), (EXDEV, "uninstall_cross_volume"),
            (EBUSY, "uninstall_locked"), (ETXTBSY, "uninstall_locked"),
            (ENOSPC, "uninstall_disk_full"), (EDQUOT, "uninstall_disk_full"),
            (EIO, "uninstall_boundary_failed")
        ] {
            let failure = rejected(source, errorNumber: number)
            XCTAssertEqual(failure.code, expected)
            XCTAssertEqual(failure.errno, number)
            XCTAssertEqual(failure.operation, "privileged_trash")
        }
        XCTAssertEqual(rejected(source, errorNumber: nil).code, "uninstall_helper_safety_refused")
    }
}
