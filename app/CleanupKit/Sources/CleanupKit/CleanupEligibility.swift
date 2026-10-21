import Foundation

public enum CleanupFailureKind: String, CaseIterable, Sendable {
    case inUse, permissionDenied, protectedResource, missing, changed, cancelled, busy, unknown
}
public struct CleanupFailure: Sendable {
    public var path: String
    public var name: String
    public var kind: CleanupFailureKind
    public var detail: String
    public init(path: String, name: String, kind: CleanupFailureKind, detail: String = "") {
        self.path = path; self.name = name; self.kind = kind; self.detail = detail
    }
}

/// Read-only preflight, not a guarantee: the OS Trash operation remains authoritative.
/// Checking source writability alone is wrong; removing a file requires rights on its parent.
enum CleanupEligibility {
    static func canMoveToTrash(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return FileManager.default.isDeletableFile(atPath: url.path)
            && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
    static func previewBlock(for path: String, home: String,
                             browser: BrowserCleanupGuard = .live,
                             canMove: (String) -> Bool = canMoveToTrash) -> CleanupFailureKind? {
        for brand in BrowserCleanupGuard.affectedBrowsers(path: path, home: home) {
            switch browser.processState(brand) {
            case .inUse: return .inUse
            case .unknown: return .protectedResource
            case .idle: break
            }
        }
        return canMove(path) ? nil : .permissionDenied
    }
    static func classify(_ error: Error) -> CleanupFailureKind {
        var current = error as NSError
        for _ in 0..<5 {
            if current.domain == NSCocoaErrorDomain {
                if current.code == NSFileWriteNoPermissionError || current.code == NSFileReadNoPermissionError { return .permissionDenied }
                if current.code == NSFileNoSuchFileError || current.code == NSFileReadNoSuchFileError { return .missing }
            }
            if current.domain == NSPOSIXErrorDomain {
                if current.code == Int(EACCES) || current.code == Int(EPERM) { return .permissionDenied }
                if current.code == Int(ENOENT) { return .missing }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return .unknown
    }
}
