import Darwin
import Foundation

/// Unprivileged moves only. Directory descriptors pin both sides of the move;
/// no user-writable manifest is ever consumed by an administrator process.
enum UninstallFileBoundary {
    struct Identity: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
        let owner: uid_t

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            kind = value.st_mode & mode_t(S_IFMT)
            owner = value.st_uid
        }
    }

    struct Snapshot: Hashable, Sendable {
        let path: String
        let parentPath: String
        let name: String
        let parent: Identity
        let item: Identity
    }

    struct Failure: LocalizedError, Sendable {
        let code: String
        let path: String
        let errno: Int32?
        let operation: String?

        init(code: String, path: String, errno: Int32? = nil, operation: String? = nil) {
            self.code = code
            self.path = path
            self.errno = errno
            self.operation = operation
        }

        var errorDescription: String? { "\(code):\(path)" }
    }

    static func snapshot(_ path: String) throws -> Snapshot {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains("..") else {
            throw Failure(code: "uninstall_identity_changed", path: path)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.isEmpty, url.path != "/" else {
            throw Failure(code: "uninstall_identity_changed", path: path)
        }
        let parentPath = try physicalDirectory(url.deletingLastPathComponent().path)
        let fd = try openDirectory(parentPath)
        defer { close(fd) }
        var parent = stat()
        var item = stat()
        guard fstat(fd, &parent) == 0 else {
            throw posixFailure(path, errno: errno, operation: "snapshot.parent_stat")
        }
        guard fstatat(fd, url.lastPathComponent, &item, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixFailure(path, errno: errno, operation: "snapshot.item_stat")
        }
        return Snapshot(path: url.path, parentPath: parentPath, name: url.lastPathComponent,
                        parent: Identity(parent), item: Identity(item))
    }

    /// An unreadable or missing path is not evidence that its identity changed.
    static func validate(_ source: Snapshot) throws {
        let fresh = try snapshot(source.path)
        guard fresh.parentPath == source.parentPath && fresh.parent == source.parent && fresh.item == source.item else {
            throw Failure(code: "uninstall_identity_changed", path: source.path, operation: "validate.identity")
        }
    }

    static func stillMatches(_ source: Snapshot) -> Bool {
        do { try validate(source); return true }
        catch { return false }
    }

    static func isMissing(_ path: String) -> Bool {
        var value = stat()
        return lstat(path, &value) != 0 && errno == ENOENT
    }

    /// Passing a destination is an internal fixture seam; production uses the user's Trash.
    @discardableResult
    static func move(_ source: Snapshot, toTrashDirectory destination: String? = nil) throws -> String {
        try validate(source)
        let sourceFD = try openDirectory(source.parentPath)
        defer { close(sourceFD) }
        var parent = stat()
        var item = stat()
        guard fstat(sourceFD, &parent) == 0 else {
            throw posixFailure(source.path, errno: errno, operation: "move.parent_stat")
        }
        guard fstatat(sourceFD, source.name, &item, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixFailure(source.path, errno: errno, operation: "move.item_stat")
        }
        guard Identity(parent) == source.parent, Identity(item) == source.item else {
            throw Failure(code: "uninstall_identity_changed", path: source.path)
        }

        let trashPath: String
        if let destination {
            trashPath = destination
        } else {
            trashPath = try defaultTrashPath(for: source)
        }
        let trashFD: Int32
        do { trashFD = try openDirectory(trashPath) }
        catch let failure as Failure where failure.errno == ELOOP || failure.errno == ENOTDIR {
            // O_NOFOLLOW must keep rejecting a symlink/non-directory Trash;
            // permission and other I/O failures retain their own diagnosis.
            throw Failure(code: "uninstall_trash_unsafe", path: trashPath,
                          errno: failure.errno, operation: failure.operation)
        }
        defer { close(trashFD) }
        var trash = stat()
        guard fstat(trashFD, &trash) == 0 else {
            throw posixFailure(trashPath, errno: errno, operation: "move.trash_stat")
        }
        guard trash.st_uid == getuid(), trash.st_mode & 0o022 == 0 else {
            throw Failure(code: "uninstall_trash_unsafe", path: trashPath)
        }
        guard trash.st_dev == source.item.device else {
            throw Failure(code: "uninstall_cross_volume", path: source.path, operation: "move.trash_device")
        }
        // Rebind the public destination name too. The descriptor remains pinned even
        // if another process renames its ancestors after this check.
        let recheckFD = try openDirectory(trashPath)
        defer { close(recheckFD) }
        var freshTrash = stat()
        guard fstat(recheckFD, &freshTrash) == 0 else {
            throw posixFailure(trashPath, errno: errno, operation: "move.trash_recheck_stat")
        }
        guard Identity(freshTrash) == Identity(trash) else {
            throw Failure(code: "uninstall_identity_changed", path: source.path)
        }
        try validate(source)

        for attempt in 0..<100 {
            let name = attempt == 0 ? source.name : "\(source.name).\(UUID().uuidString)"
            if renameatx_np(sourceFD, source.name, trashFD, name, UInt32(RENAME_EXCL)) == 0 {
                return (trashPath as NSString).appendingPathComponent(name)
            }
            let errorNumber = errno
            if errorNumber == EEXIST { continue }
            throw posixFailure(source.path, errno: errorNumber, operation: "renameatx_np")
        }
        throw Failure(code: "uninstall_trash_unsafe", path: trashPath)
    }

    private static func defaultTrashPath(for source: Snapshot) throws -> String {
        let fm = FileManager.default
        let home = try physicalDirectory(fm.homeDirectoryForCurrentUser.path)
        let homeFD = try openDirectory(home)
        defer { close(homeFD) }
        var info = stat()
        guard fstat(homeFD, &info) == 0 else {
            throw posixFailure(home, errno: errno, operation: "trash.home_stat")
        }
        guard info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw Failure(code: "uninstall_trash_unsafe", path: home)
        }
        if info.st_dev == source.item.device {
            if mkdirat(homeFD, ".Trash", 0o700) != 0 {
                let errorNumber = errno
                if errorNumber != EEXIST {
                    throw posixFailure(home + "/.Trash", errno: errorNumber, operation: "mkdirat")
                }
            }
            return (home as NSString).appendingPathComponent(".Trash")
        }
        // Finder owns cross-volume compatibility. Never fall back to copy-and-delete.
        do {
            return try fm.url(for: .trashDirectory, in: .userDomainMask,
                              appropriateFor: URL(fileURLWithPath: source.path), create: false).path
        } catch {
            throw fileSystemFailure(error, path: source.path, operation: "trash_directory_lookup")
        }
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains("..") else {
            throw Failure(code: "uninstall_boundary_failed", path: path, operation: "open_directory.path_validation")
        }
        // Foundation can respell /private/var as /var even after resolvingSymlinks.
        // Resolve only these fixed platform aliases, never a user-controlled ancestor.
        var traversal = path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            traversal = "/private" + path
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure(path, errno: errno, operation: "open_directory.root") }
        for component in traversal.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let saved = errno
                close(fd)
                throw posixFailure(path, errno: saved, operation: "open_directory.component")
            }
            close(fd)
            fd = next
        }
        return fd
    }

    private static func physicalDirectory(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw posixFailure(path, errno: errno, operation: "realpath")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Explicit errno also makes error classification testable without provoking
    /// failures on real applications, disks, or the user's Trash.
    static func posixFailure(_ path: String, errno errorNumber: Int32, operation: String) -> Failure {
        let code: String
        switch errorNumber {
        case EACCES: code = "uninstall_permission_denied"
        case EPERM: code = "uninstall_operation_not_permitted"
        case EROFS: code = "uninstall_read_only"
        case EXDEV: code = "uninstall_cross_volume"
        case ENOENT: code = "uninstall_missing"
        case EBUSY, ETXTBSY: code = "uninstall_locked"
        case ENOSPC, EDQUOT: code = "uninstall_disk_full"
        default: code = "uninstall_boundary_failed"
        }
        return Failure(code: code, path: path, errno: errorNumber, operation: operation)
    }

    static func fileSystemFailure(_ error: Error, path: String, operation: String) -> Failure {
        var current = error as NSError
        var cocoaCode: String?
        // Foundation can wrap the useful POSIX error; bound traversal in case an
        // unusual error chain is cyclic. Do not fabricate errno for Cocoa-only errors.
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain, let errorNumber = Int32(exactly: current.code) {
                return posixFailure(path, errno: errorNumber, operation: operation)
            }
            if current.domain == NSCocoaErrorDomain {
                switch current.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: cocoaCode = "uninstall_permission_denied"
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError: cocoaCode = "uninstall_missing"
                case NSFileWriteVolumeReadOnlyError: cocoaCode = "uninstall_read_only"
                case NSFileWriteOutOfSpaceError: cocoaCode = "uninstall_disk_full"
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return Failure(code: cocoaCode ?? "uninstall_manual_required", path: path, operation: operation)
    }
}
