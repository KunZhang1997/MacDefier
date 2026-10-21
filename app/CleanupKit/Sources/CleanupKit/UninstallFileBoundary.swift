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

    struct Failure: LocalizedError {
        let code: String
        let path: String
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
        guard fstat(fd, &parent) == 0,
              fstatat(fd, url.lastPathComponent, &item, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixFailure(path)
        }
        return Snapshot(path: url.path, parentPath: parentPath, name: url.lastPathComponent,
                        parent: Identity(parent), item: Identity(item))
    }

    static func stillMatches(_ source: Snapshot) -> Bool {
        guard let fresh = try? snapshot(source.path) else { return false }
        return fresh.parentPath == source.parentPath && fresh.parent == source.parent && fresh.item == source.item
    }

    static func isMissing(_ path: String) -> Bool {
        var value = stat()
        return lstat(path, &value) != 0 && errno == ENOENT
    }

    /// Passing a destination is an internal fixture seam; production uses the user's Trash.
    @discardableResult
    static func move(_ source: Snapshot, toTrashDirectory destination: String? = nil) throws -> String {
        guard stillMatches(source) else {
            throw Failure(code: "uninstall_identity_changed", path: source.path)
        }
        let sourceFD = try openDirectory(source.parentPath)
        defer { close(sourceFD) }
        var parent = stat()
        var item = stat()
        guard fstat(sourceFD, &parent) == 0, Identity(parent) == source.parent,
              fstatat(sourceFD, source.name, &item, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(item) == source.item else {
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
        catch { throw Failure(code: "uninstall_trash_unsafe", path: trashPath) }
        defer { close(trashFD) }
        var trash = stat()
        guard fstat(trashFD, &trash) == 0,
              trash.st_uid == getuid(), trash.st_mode & 0o022 == 0,
              trash.st_dev == source.item.device else {
            throw Failure(code: "uninstall_trash_unsafe", path: trashPath)
        }
        // Rebind the public destination name too. The descriptor remains pinned even
        // if another process renames its ancestors after this check.
        let recheckFD = try openDirectory(trashPath)
        defer { close(recheckFD) }
        var freshTrash = stat()
        guard fstat(recheckFD, &freshTrash) == 0, Identity(freshTrash) == Identity(trash),
              stillMatches(source) else {
            throw Failure(code: "uninstall_identity_changed", path: source.path)
        }

        for attempt in 0..<100 {
            let name = attempt == 0 ? source.name : "\(source.name).\(UUID().uuidString)"
            if renameatx_np(sourceFD, source.name, trashFD, name, UInt32(RENAME_EXCL)) == 0 {
                return (trashPath as NSString).appendingPathComponent(name)
            }
            if errno == EEXIST { continue }
            throw posixFailure(source.path)
        }
        throw Failure(code: "uninstall_trash_unsafe", path: trashPath)
    }

    private static func defaultTrashPath(for source: Snapshot) throws -> String {
        let fm = FileManager.default
        let home = try physicalDirectory(fm.homeDirectoryForCurrentUser.path)
        let homeFD = try openDirectory(home)
        defer { close(homeFD) }
        var info = stat()
        guard fstat(homeFD, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw Failure(code: "uninstall_trash_unsafe", path: home)
        }
        if info.st_dev == source.item.device {
            if mkdirat(homeFD, ".Trash", 0o700) != 0, errno != EEXIST { throw posixFailure(home) }
            return (home as NSString).appendingPathComponent(".Trash")
        }
        // Finder owns cross-volume compatibility. Never fall back to copy-and-delete.
        guard let url = try? fm.url(for: .trashDirectory, in: .userDomainMask,
                                    appropriateFor: URL(fileURLWithPath: source.path), create: false) else {
            throw Failure(code: "uninstall_manual_required", path: source.path)
        }
        return url.path
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains("..") else { throw posixFailure(path) }
        // Foundation can respell /private/var as /var even after resolvingSymlinks.
        // Resolve only these fixed platform aliases, never a user-controlled ancestor.
        var traversal = path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            traversal = "/private" + path
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure(path) }
        for component in traversal.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let saved = errno
                close(fd)
                errno = saved
                throw posixFailure(path)
            }
            close(fd)
            fd = next
        }
        return fd
    }

    private static func physicalDirectory(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw posixFailure(path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func posixFailure(_ path: String) -> Failure {
        let code = errno == EACCES || errno == EPERM || errno == EROFS || errno == EXDEV
            ? "uninstall_manual_required" : "uninstall_boundary_failed"
        return Failure(code: code, path: path)
    }
}
