import XCTest
@testable import CleanupKit

final class UninstallCommandFailureTests: XCTestCase {
    func testPermissionReasonsRemainDistinct() {
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "npm ERR! code EACCES", exitCode: 1), "command_permission_denied")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "Permission denied: /fixture/package", exitCode: 1), "command_permission_denied")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "npm ERR! code EPERM", exitCode: 1), "command_operation_not_permitted")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "Operation not permitted", exitCode: 1), "command_operation_not_permitted")
    }

    func testReadOnlyQuotaAndBusyReasons() {
        let cases = [
            ("EROFS: read-only file system", "command_read_only"),
            ("No space left on device", "command_disk_full"),
            ("EDQUOT", "command_disk_full"),
            ("EBUSY: resource busy", "command_locked"),
            ("ETXTBSY", "command_locked"),
            ("The file is locked", "command_locked")
        ]
        for (diagnostic, expected) in cases {
            XCTAssertEqual(UninstallCommandFailure.code(stderr: diagnostic, exitCode: 1), expected)
        }
    }

    func testInteractiveAuthorizationIsNotTreatedAsFileMovePermission() {
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "sudo: a terminal is required to read the password", exitCode: 1), "command_authorization_required")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "This command must be run as root", exitCode: 1), "command_authorization_required")
    }

    func testDependencyRefusalHasSpecificReason() {
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "Error: Refusing to uninstall /fixture/lib because it is required by another-tool, which is currently installed.", exitCode: 1), "command_dependencies_blocked")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "Cannot uninstall: other packages depend on this dependency", exitCode: 1), "command_dependencies_blocked")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "Downloading dependency metadata failed", exitCode: 1), "command_failed")
    }

    func testMissingCommandsAndRuntimeCanBeIdentified() {
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "zsh: command not found: uv", exitCode: 127), "command_not_found")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "env: node: No such file or directory", exitCode: 127), "command_not_found")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "", exitCode: 126), "command_not_executable")
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "launch_failed", exitCode: -1), "command_launch_failed")
    }

    func testMissingDataFileDoesNotClaimCommandIsMissing() {
        XCTAssertEqual(UninstallCommandFailure.code(stderr: "No such file or directory: /fixture/package/metadata", exitCode: 1), "command_failed")
    }

    func testBoundedExecutionReasonsArePreserved() {
        for code in ["timeout", "cancelled", "output_limit"] {
            XCTAssertEqual(UninstallCommandFailure.code(stderr: code, exitCode: -1), code)
        }
    }

    func testUnknownDiagnosticCannotLeakSecretsOrPaths() {
        let diagnostic = "failed token=fixture-secret https://fixture.invalid/auth?token=fixture-secret /fixture/private/config"
        let code = UninstallCommandFailure.code(stderr: diagnostic, exitCode: 1)
        XCTAssertEqual(code, "command_failed")
        XCTAssertFalse(code.contains("fixture-secret"))
        XCTAssertFalse(code.contains("/fixture"))
    }
}
