import AppKit
import Darwin
import Foundation
import SwiftUI

/// The UI receives structured refusal codes, never shell output as user-facing copy.
enum UninstallErrorText {
    struct Entry: Identifiable, Sendable {
        let id: Int
        let messageKey: String
        let path: String?
        let revealURL: URL?

        var message: String { L10n.t(messageKey) }
    }

    /// Prepare once after an operation, off the render loop. Unknown tool errors
    /// deliberately omit raw stderr, which can contain commands or script details.
    static func entries(for errors: [String]) -> [Entry] {
        errors.enumerated().map { index, error in
            // Legacy TrashError uses a full-width colon; split once so a colon
            // inside a legitimate macOS filename remains part of the path.
            let parts = error.split(maxSplits: 1, omittingEmptySubsequences: false,
                                    whereSeparator: { $0 == ":" || $0 == "：" })
            let code = parts.first.map(String.init) ?? ""
            let key: String
            var carriesPath = false
            switch code {
            case "resource_mutation_busy": key = "aitools.reason.resource_mutation_busy"
            case "ai_cleanup_in_use": key = "aitools.reason.in_use"; carriesPath = true
            case "ai_cleanup_probe_unknown": key = "aitools.reason.probe_unknown"; carriesPath = true
            case "ai_cleanup_open_files": key = "aitools.reason.open_files"; carriesPath = true
            case "ai_cleanup_handle_probe_unknown": key = "aitools.reason.handle_probe_unknown"; carriesPath = true
            case "ai_cleanup_changed": key = "aitools.reason.changed"; carriesPath = true
            case "ai_cleanup_dedicated_preview_required": key = "aitools.reason.dedicated_preview_required"; carriesPath = true
            case "uninstall_identity_changed": key = "uninstall.error.identity_changed"; carriesPath = true
            case "uninstall_application_metadata_unavailable": key = "uninstall.error.application_metadata_unavailable"; carriesPath = true
            case "uninstall_application_metadata_invalid": key = "uninstall.error.application_metadata_invalid"; carriesPath = true
            case "uninstall_container_unverified": key = "uninstall.error.container_unverified"; carriesPath = true
            case "uninstall_container_in_use": key = "uninstall.error.container_in_use"; carriesPath = true
            case "uninstall_container_shared": key = "uninstall.error.container_shared"; carriesPath = true
            case "uninstall_container_changed": key = "uninstall.error.container_changed"; carriesPath = true
            case "uninstall_extension_unverified": key = "uninstall.error.extension_unverified"; carriesPath = true
            case "uninstall_trash_unsafe": key = "uninstall.error.trash_unsafe"; carriesPath = true
            case "uninstall_manual_required": key = "uninstall.error.manual_required"; carriesPath = true
            case "uninstall_permission_denied": key = "uninstall.error.permission_denied"; carriesPath = true
            case "uninstall_operation_not_permitted": key = "uninstall.error.operation_not_permitted"; carriesPath = true
            case "uninstall_read_only": key = "uninstall.error.read_only"; carriesPath = true
            case "uninstall_cross_volume": key = "uninstall.error.cross_volume"; carriesPath = true
            case "uninstall_missing", "路径不存在": key = "uninstall.error.missing"; carriesPath = true
            case "uninstall_locked": key = "uninstall.error.locked"; carriesPath = true
            case "uninstall_disk_full": key = "uninstall.error.disk_full"; carriesPath = true
            case "uninstall_authorization_cancelled": key = "uninstall.error.authorization_cancelled"; carriesPath = true
            case "uninstall_system_result_unknown": key = "uninstall.error.system_result_unknown"; carriesPath = true
            case "uninstall_helper_signature_invalid": key = "uninstall.error.helper_signature"; carriesPath = true
            case "uninstall_helper_configuration_missing": key = "uninstall.error.helper_configuration"; carriesPath = true
            case "uninstall_helper_unavailable", "uninstall_helper_root_required": key = "uninstall.error.helper_unavailable"; carriesPath = true
            case "uninstall_helper_registration_failed": key = "uninstall.error.helper_registration"; carriesPath = true
            case "uninstall_helper_approval_required": key = "uninstall.error.helper_approval"; carriesPath = true
            case "uninstall_helper_authorization_denied": key = "uninstall.error.helper_authorization_denied"; carriesPath = true
            case "uninstall_helper_authorization_invalid": key = "uninstall.error.helper_authorization_invalid"; carriesPath = true
            case "uninstall_helper_authorization_policy_invalid": key = "uninstall.error.helper_authorization_policy_invalid"; carriesPath = true
            case "uninstall_helper_authorization_expired": key = "uninstall.error.helper_authorization_expired"; carriesPath = true
            case "uninstall_helper_update_required": key = "uninstall.error.helper_update_required"; carriesPath = true
            case "uninstall_helper_connection_invalid", "uninstall_helper_request_invalid", "uninstall_helper_caller_invalid": key = "uninstall.error.helper_safety"; carriesPath = true
            case "uninstall_helper_scope_rejected": key = "uninstall.error.helper_scope"; carriesPath = true
            case "uninstall_helper_recovery_required": key = "uninstall.error.helper_recovery"; carriesPath = true
            case "uninstall_helper_restored": key = "uninstall.error.helper_restored"; carriesPath = true
            case "uninstall_helper_safety_refused": key = "uninstall.error.helper_safety"; carriesPath = true
            case "uninstall_link_manual": key = "uninstall.error.link_manual"; carriesPath = true
            case "uninstall_finder_permission": key = "uninstall.error.finder_permission"; carriesPath = true
            case "uninstall_boundary_failed": key = "uninstall.error.boundary_failed"; carriesPath = true
            case "uninstall_data_preserved": key = "uninstall.error.data_preserved"; carriesPath = true
            case "cli_data_preserved_program_failed": key = "uninstall.error.cli_data_preserved"
            case "cli_manual_owner_changed": key = "uninstall.error.cli_manual_owner_changed"; carriesPath = true
            case "cli_manual_shared_root": key = "uninstall.error.cli_manual_shared_root"; carriesPath = true
            case "cli_manual_ownership_unverified": key = "uninstall.error.cli_manual_ownership_unverified"; carriesPath = true
            case "cli_agent_owner_changed": key = "uninstall.error.cli_agent_owner_changed"; carriesPath = true
            case "cli_agent_stop_failed": key = "uninstall.error.cli_agent_stop_failed"; carriesPath = true
            case "output_limit": key = "uninstall.error.output_limit"
            case "timeout": key = "uninstall.error.timed_out"
            case "移入废纸篓超时（可能在等系统授权），结果未知按失败处理": key = "uninstall.error.timed_out"; carriesPath = true
            case "cancelled": key = "uninstall.error.cancelled"
            case "program_still_present": key = "uninstall.error.program_still_present"
            case "protected": key = "cli.uninstall.err.protected"
            case "npm_prefix": key = "uninstall.error.npm_prefix"
            case "npm_missing", "brew_missing", "uv_missing", "command_not_found": key = "uninstall.error.command_not_found"
            case "npm_failed": key = "cli.uninstall.err.npm"
            case "brew_failed": key = "cli.uninstall.err.brew"
            case "uv_failed": key = "cli.uninstall.err.uv"
            case "command_permission_denied": key = "uninstall.error.command_permission_denied"
            case "command_operation_not_permitted": key = "uninstall.error.command_operation_not_permitted"
            case "command_read_only": key = "uninstall.error.command_read_only"
            case "command_locked": key = "uninstall.error.command_locked"
            case "command_disk_full": key = "uninstall.error.disk_full"
            case "command_authorization_required": key = "uninstall.error.command_authorization_required"
            case "command_dependencies_blocked": key = "uninstall.error.command_dependencies_blocked"
            case "command_not_executable": key = "uninstall.error.command_not_executable"
            case "command_launch_failed": key = "uninstall.error.command_launch_failed"
            case "command_failed": key = "uninstall.error.command_failed"
            case "manual_program": key = "cli.uninstall.err.manual"
            case "protected_data": key = "cli.uninstall.err.protected_data"
            case "blocked", "安全策略拒绝": key = "cli.uninstall.err.blocked"; carriesPath = true
            default: key = "uninstall.error.unknown"
            }
            let path = carriesPath && parts.count == 2 ? validAbsolutePath(String(parts[1])) : nil
            return Entry(id: index, messageKey: key, path: path,
                         revealURL: path.flatMap(existingURL(for:)))
        }
    }

    static func existingURL(for path: String) -> URL? {
        guard let path = validAbsolutePath(path) else { return nil }
        var info = stat()
        // lstat recognizes a dangling link itself without following its target.
        guard lstat(path, &info) == 0 else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func validAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return path
    }
}

/// Shared native error presentation. Finder is an explicit, read-only follow-up;
/// this row never retries deletion or requests administrator privileges.
struct UninstallErrorRow: View {
    let entry: UninstallErrorText.Entry
    var tint: Color = .orange
    @State private var revealUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            if let path = entry.path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = entry.revealURL, !revealUnavailable {
                Button {
                    guard let current = UninstallErrorText.existingURL(for: url.path) else {
                        revealUnavailable = true
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([current])
                } label: {
                    Label(L10n.t("uninstall.error.show_finder"), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.t("uninstall.error.finder_label", url.lastPathComponent))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
