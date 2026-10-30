import Darwin
import Foundation
import UninstallHelperClient
import UninstallHelperCore
import UninstallHelperIPC

enum UninstallPrivilegedTrash {
    /// Called only for the selected main bundle, after the ordinary move has
    /// failed with a permission error. Residuals and CLI tools never enter here.
    static func move(_ source: UninstallFileBoundary.Snapshot) async throws {
        guard source.parentPath == "/Applications", source.path == "/Applications/" + source.name,
              source.name.hasSuffix(".app"), source.item.kind == mode_t(S_IFDIR) else {
            throw UninstallFileBoundary.Failure(code: "uninstall_helper_scope_rejected", path: source.path)
        }
        func identity(_ value: UninstallFileBoundary.Identity) -> UninstallFileIdentity {
            .init(device: Int64(value.device), inode: UInt64(value.inode), kind: UInt32(value.kind), owner: value.owner)
        }
        let request = UninstallRequest(sourcePath: source.path, expectedItem: identity(source.item), expectedParent: identity(source.parent))
        do {
            let result = try await UninstallHelperClient.shared.move(request)
            switch result.disposition {
            case .moved:
                // The signed service verified the staged object's identity before
                // committing it. Do not require a new FDA-protected Trash read.
                guard result.reason == nil, result.destinationPath != nil, UninstallFileBoundary.isMissing(source.path) else {
                    throw UninstallFileBoundary.Failure(code: "uninstall_system_result_unknown", path: source.path)
                }
            case .committedUnknown:
                throw UninstallFileBoundary.Failure(code: "uninstall_system_result_unknown", path: source.path)
            case .retainedStaging:
                throw UninstallFileBoundary.Failure(code: "uninstall_helper_recovery_required", path: result.recoveryPath ?? source.path)
            case .recoveredOriginal:
                throw UninstallFileBoundary.Failure(code: "uninstall_helper_restored", path: source.path)
            case .rejected:
                throw rejected(result, source: source.path)
            }
        } catch let failure as UninstallHelperFailure {
            throw UninstallFileBoundary.Failure(code: failure.code, path: source.path)
        } catch let failure as UninstallCoreFailure {
            throw UninstallFileBoundary.Failure(code: failure.code == "helper_source_identity_changed"
                ? "uninstall_identity_changed" : "uninstall_helper_scope_rejected", path: source.path)
        } catch is CancellationError {
            throw UninstallFileBoundary.Failure(code: "uninstall_authorization_cancelled", path: source.path)
        }
    }

    static func rejected(_ result: UninstallResult, source: String) -> UninstallFileBoundary.Failure {
        // The errno can refer to an internal bundle file, not the selected app.
        // Preserve the helper's specific metadata, identity and scope decisions.
        let code: String?
        switch result.reason {
        case "helper_source_identity_changed", "helper_source_parent_changed", "helper_staged_identity_changed": code = "uninstall_identity_changed"
        case "helper_cross_volume": code = "uninstall_cross_volume"
        case "helper_protected_application", "helper_source_path_rejected": code = "uninstall_helper_scope_rejected"
        case "helper_application_metadata_unavailable": code = "uninstall_application_metadata_unavailable"
        case "helper_application_metadata_invalid": code = "uninstall_application_metadata_invalid"
        default: code = nil
        }
        if let code {
            return .init(code: code, path: source, errno: result.errno, operation: "privileged_trash")
        }
        if let number = result.errno {
            // lstat distinguishes a missing source from a present dangling link
            // or an unreadable path. Neither is proof that the app disappeared.
            if number == ENOENT && !UninstallFileBoundary.isMissing(source) {
                return .init(code: "uninstall_helper_safety_refused", path: source,
                             errno: number, operation: "privileged_trash")
            }
            return UninstallFileBoundary.posixFailure(source, errno: number, operation: "privileged_trash")
        }
        return .init(code: "uninstall_helper_safety_refused", path: source, operation: "privileged_trash")
    }
}
