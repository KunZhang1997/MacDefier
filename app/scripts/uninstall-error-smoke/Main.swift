import Foundation
import Darwin

// Compile with the real UninstallErrorText.swift. This runner creates no app,
// launches no process and supplies only synthetic, non-user paths.
enum L10n {
    static func t(_ key: String, _ arguments: CVarArg...) -> String { key }
}

@main struct UninstallErrorSmoke {
    static func main() {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let path = "/fixture-only/macdefier-uninstall-errors/missing-item"
        let reasons = [
            ("uninstall_application_metadata_unavailable", "application_metadata_unavailable"),
            ("uninstall_application_metadata_invalid", "application_metadata_invalid"),
            ("uninstall_container_unverified", "container_unverified"),
            ("uninstall_container_in_use", "container_in_use"),
            ("uninstall_container_shared", "container_shared"),
            ("uninstall_container_changed", "container_changed"),
            ("uninstall_extension_unverified", "extension_unverified"),
            ("uninstall_permission_denied", "permission_denied"),
            ("uninstall_operation_not_permitted", "operation_not_permitted"),
            ("uninstall_read_only", "read_only"),
            ("uninstall_cross_volume", "cross_volume"),
            ("uninstall_missing", "missing"),
            ("uninstall_locked", "locked"),
            ("uninstall_disk_full", "disk_full"),
            ("uninstall_authorization_cancelled", "authorization_cancelled"),
            ("uninstall_system_result_unknown", "system_result_unknown"),
            ("uninstall_helper_recovery_required", "helper_recovery"),
            ("uninstall_helper_restored", "helper_restored"),
            ("uninstall_helper_signature_invalid", "helper_signature"),
            ("uninstall_helper_configuration_missing", "helper_configuration"),
            ("uninstall_helper_unavailable", "helper_unavailable"),
            ("uninstall_helper_registration_failed", "helper_registration"),
            ("uninstall_helper_approval_required", "helper_approval"),
            ("uninstall_helper_authorization_denied", "helper_authorization_denied"),
            ("uninstall_helper_authorization_invalid", "helper_authorization_invalid"),
            ("uninstall_helper_authorization_policy_invalid", "helper_authorization_policy_invalid"),
            ("uninstall_helper_authorization_expired", "helper_authorization_expired"),
            ("uninstall_helper_update_required", "helper_update_required"),
            ("uninstall_helper_scope_rejected", "helper_scope"),
            ("uninstall_helper_safety_refused", "helper_safety"),
            ("uninstall_link_manual", "link_manual"),
            ("uninstall_finder_permission", "finder_permission")
        ]
        for (code, key) in reasons {
            let entry = UninstallErrorText.entries(for: [code + ":" + path])[0]
            check(entry.messageKey == "uninstall.error." + key && entry.path == path, code)
        }
        let commands = [
            ("command_permission_denied", "command_permission_denied"),
            ("command_operation_not_permitted", "command_operation_not_permitted"),
            ("command_read_only", "command_read_only"),
            ("command_locked", "command_locked"),
            ("command_disk_full", "disk_full"),
            ("command_authorization_required", "command_authorization_required"),
            ("command_dependencies_blocked", "command_dependencies_blocked"),
            ("command_not_found", "command_not_found"),
            ("command_not_executable", "command_not_executable"),
            ("command_launch_failed", "command_launch_failed"),
            ("command_failed", "command_failed")
        ]
        for (code, key) in commands {
            let entry = UninstallErrorText.entries(for: [code + ":" + path])[0]
            check(entry.messageKey == "uninstall.error." + key && entry.path == nil && entry.revealURL == nil,
                  code + " cannot authorize or reveal a stderr path")
        }
        let legacyBlocked = UninstallErrorText.entries(for: ["安全策略拒绝：" + path])[0]
        check(legacyBlocked.messageKey == "cli.uninstall.err.blocked" && legacyBlocked.path == path, "legacy blocked uses full-width colon")
        let legacyMissing = UninstallErrorText.entries(for: ["路径不存在：" + path])[0]
        check(legacyMissing.messageKey == "uninstall.error.missing" && legacyMissing.path == path, "legacy missing uses full-width colon")
        let colonPath = UninstallErrorText.entries(for: ["uninstall_locked:" + path + ":part"])[0]
        check(colonPath.path == path + ":part", "colon inside filename is preserved")
        let unknown = UninstallErrorText.entries(for: ["private token=fixture-secret:" + path])[0]
        check(unknown.messageKey == "uninstall.error.unknown" && unknown.path == nil, "unknown diagnostics are not exposed")
        let unsafe = UninstallErrorText.entries(for: ["uninstall_locked:" + path + "\nfixture-secret"])[0]
        check(unsafe.path == nil && unsafe.revealURL == nil, "control-character path is not revealed")
        print("RESULT error parser checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
