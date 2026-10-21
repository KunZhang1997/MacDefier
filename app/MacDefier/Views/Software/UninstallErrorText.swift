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
            let parts = error.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
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
            case "uninstall_trash_unsafe": key = "uninstall.error.trash_unsafe"; carriesPath = true
            case "uninstall_manual_required": key = "uninstall.error.manual_required"; carriesPath = true
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
            case "cancelled": key = "uninstall.error.cancelled"
            case "program_still_present": key = "uninstall.error.program_still_present"
            case "protected": key = "cli.uninstall.err.protected"
            case "npm_prefix", "npm_missing", "npm_failed": key = "cli.uninstall.err.npm"
            case "brew_missing", "brew_failed": key = "cli.uninstall.err.brew"
            case "uv_missing", "uv_failed": key = "cli.uninstall.err.uv"
            case "manual_program": key = "cli.uninstall.err.manual"
            case "protected_data": key = "cli.uninstall.err.protected_data"
            case "blocked": key = "cli.uninstall.err.blocked"; carriesPath = true
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
