import Darwin
import Foundation

/// Production remains an ordinary, identity-checked move. Finder's authorization
/// wait can bind an earlier pathname and later act on its replacement, even when
/// sent a file-reference URL. Do not enable it as a privileged fallback.
enum UninstallSystemTrash {
    typealias Recycle = @Sendable (UninstallFileBoundary.Snapshot) async throws -> String

    static func move(_ source: UninstallFileBoundary.Snapshot,
                     ordinaryMove: (UninstallFileBoundary.Snapshot) throws -> String = { try UninstallFileBoundary.move($0) },
                     recycle: Recycle? = nil) async throws -> String {
        try Task.checkCancellation()
        do { return try ordinaryMove(source) }
        catch let failure as UninstallFileBoundary.Failure {
            guard failure.code == "uninstall_permission_denied" || failure.code == "uninstall_operation_not_permitted" else { throw failure }
            try Task.checkCancellation()
            // Immutable/append-only flags are a locked item, not a password request.
            var info = stat()
            if lstat(source.path, &info) == 0,
               info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 {
                throw UninstallFileBoundary.Failure(code: "uninstall_locked", path: source.path)
            }
            // Injection is only an isolated regression seam. Production callers
            // never supply it and must retain the actual permission failure.
            guard let recycle else { throw failure }
            try UninstallFileBoundary.validate(source)
            guard source.item.kind != mode_t(S_IFLNK) else {
                throw UninstallFileBoundary.Failure(code: "uninstall_link_manual", path: source.path)
            }
            let destination: String
            do { destination = try await recycle(source) }
            catch { throw classify(error, path: source.path) }
            // The callback must acknowledge this exact object. An absent source
            // alone could be a concurrent rename and is never proof of success.
            // Only stat the exact receipt. Opening/listing the Trash directory
            // again would reintroduce the permission failure we just recovered.
            var moved = stat()
            guard UninstallFileBoundary.isMissing(source.path), lstat(destination, &moved) == 0,
                  UninstallFileBoundary.Identity(moved) == source.item else {
                throw UninstallFileBoundary.Failure(code: "uninstall_system_result_unknown", path: source.path)
            }
            return destination
        }
    }

    static func classify(_ error: Error, path: String) -> UninstallFileBoundary.Failure {
        if let failure = error as? UninstallFileBoundary.Failure { return failure }
        if error is CancellationError { return .init(code: "uninstall_authorization_cancelled", path: path) }
        var current = error as NSError
        for _ in 0..<6 {
            if (current.domain == NSCocoaErrorDomain && current.code == NSUserCancelledError)
                || (current.domain == NSOSStatusErrorDomain && [NSUserCancelledError, -128, -60006].contains(current.code)) {
                return .init(code: "uninstall_authorization_cancelled", path: path)
            }
            if current.domain == "MacDefier.SystemTrash", current.code == 1 {
                return .init(code: "uninstall_identity_changed", path: path)
            }
            if current.domain == NSOSStatusErrorDomain {
                let codes = [-1743: "uninstall_finder_permission", -5000: "uninstall_permission_denied",
                             -54: "uninstall_permission_denied", -45: "uninstall_locked", -43: "uninstall_missing"]
                if let code = codes[current.code] { return .init(code: code, path: path) }
            }
            if current.domain == NSPOSIXErrorDomain {
                let codes: [Int: String] = [Int(EACCES): "uninstall_permission_denied", Int(EPERM): "uninstall_operation_not_permitted",
                    Int(EROFS): "uninstall_read_only", Int(EXDEV): "uninstall_cross_volume", Int(ENOENT): "uninstall_missing",
                    Int(EBUSY): "uninstall_locked", Int(ENOSPC): "uninstall_disk_full", Int(EDQUOT): "uninstall_disk_full"]
                if let code = codes[current.code] { return .init(code: code, path: path, errno: Int32(current.code), operation: "system_trash") }
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { current = underlying; continue }
            if current.domain == NSCocoaErrorDomain,
               [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(current.code) {
                return .init(code: "uninstall_permission_denied", path: path)
            }
            break
        }
        return .init(code: "uninstall_system_result_unknown", path: path)
    }
}
