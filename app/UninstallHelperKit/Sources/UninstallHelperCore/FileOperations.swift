import Darwin
import Foundation

final class DirectoryHandle {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { close(fd) }
    func identity() throws -> UninstallFileIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw UninstallCoreFailure("helper_stat_failed", errno: errno) }
        return UninstallFileIdentity(value)
    }
}

enum FileOperations {
    static func isAbsoluteNormalized(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && !path.contains("//") &&
        (path == "/" || !path.hasSuffix("/")) &&
        !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    static func openDirectory(_ path: String, rootAncestors: Bool = false) throws -> DirectoryHandle {
        guard isAbsoluteNormalized(path) else { throw UninstallCoreFailure("helper_path_rejected") }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw UninstallCoreFailure("helper_open_failed", errno: errno) }
        var current = DirectoryHandle(root)
        if rootAncestors { try requireOwnerAndPermissions(current.fd, owner: 0, rejectAllowACL: true) }
        for component in path.split(separator: "/") {
            current = try openChildDirectory(current.fd, name: String(component))
            if rootAncestors { try requireOwnerAndPermissions(current.fd, owner: 0, rejectAllowACL: true) }
        }
        return current
    }

    static func openChildDirectory(_ parent: Int32, name: String) throws -> DirectoryHandle {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UninstallCoreFailure("helper_open_failed", errno: errno) }
        return DirectoryHandle(fd)
    }

    static func identity(at parent: Int32, name: String) throws -> UninstallFileIdentity {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw UninstallCoreFailure("helper_stat_failed", errno: errno)
        }
        return UninstallFileIdentity(value)
    }

    static func isMissing(at parent: Int32, name: String) -> Bool {
        var value = stat()
        return fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }

    static func requireBinding(path: String, identity expected: UninstallFileIdentity) throws {
        let directory = try openDirectory(path)
        guard try directory.identity() == expected else { throw UninstallCoreFailure("helper_directory_binding_changed") }
    }

    static func requireOwnerAndPermissions(_ fd: Int32, owner: UInt32, exactPrivate: Bool = false, rejectAllowACL: Bool = false) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw UninstallCoreFailure("helper_stat_failed", errno: errno) }
        guard value.st_uid == owner, value.st_mode & 0o022 == 0,
              !exactPrivate || value.st_mode & 0o777 == 0o700 else { throw UninstallCoreFailure("helper_directory_unsafe") }
        if rejectAllowACL {
            // acl_get_fd_np also returns NULL/ENOENT for an absent ACL. Query
            // the security record explicitly so absence is not confused with I/O failure.
            guard let security = filesec_init() else {
                throw UninstallCoreFailure("helper_staging_acl_unavailable", errno: errno)
            }
            defer { filesec_free(security) }
            var securityStat = stat()
            guard fstatx_np(fd, &securityStat, security) == 0 else {
                throw UninstallCoreFailure("helper_staging_acl_unavailable", errno: errno)
            }
            var hasACL: Int32 = 0
            guard filesec_query_property(security, FILESEC_ACL, &hasACL) == 0 else {
                throw UninstallCoreFailure("helper_staging_acl_unavailable", errno: errno)
            }
            if hasACL == 0 { return }
            var retrievedACL: acl_t?
            guard filesec_get_property(security, FILESEC_ACL, &retrievedACL) == 0, let acl = retrievedACL else {
                throw UninstallCoreFailure("helper_staging_acl_unavailable", errno: errno)
            }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            var selector = ACL_FIRST_ENTRY
            while true {
                let status = acl_get_entry(acl, Int32(selector.rawValue), &entry)
                if status != 0 {
                    // Darwin reports no more entries as -1 with errno EINVAL.
                    if errno == EINVAL { break }
                    throw UninstallCoreFailure("helper_staging_acl_unavailable", errno: errno)
                }
                guard let entry else { throw UninstallCoreFailure("helper_staging_acl_unavailable") }
                var tag = acl_tag_t(0)
                guard acl_get_tag_type(entry, &tag) == 0 else {
                    throw UninstallCoreFailure("helper_staging_acl_unavailable", errno: errno)
                }
                guard tag == ACL_EXTENDED_DENY else { throw UninstallCoreFailure("helper_staging_acl_unsafe") }
                selector = ACL_NEXT_ENTRY
            }
        }
    }

    static func syncDirectory(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw UninstallCoreFailure("helper_directory_sync_failed", errno: errno) }
    }

    static func renameExclusive(from parent: Int32, name: String, to destination: Int32, newName: String) throws {
        guard renameatx_np(parent, name, destination, newName, UInt32(RENAME_EXCL)) == 0 else {
            throw UninstallCoreFailure("helper_rename_failed", errno: errno)
        }
    }

    static func prepareStaging(_ context: TrustedUninstallContext) throws -> DirectoryHandle {
        var directory = try openDirectory(context.stagingAnchor, rootAncestors: context.requireRootAncestors)
        try requireOwnerAndPermissions(directory.fd, owner: context.stagingOwner, rejectAllowACL: true)
        for name in [context.serviceIdentifier, "staging"] {
            let created = mkdirat(directory.fd, name, 0o700)
            if created != 0, errno != EEXIST {
                throw UninstallCoreFailure("helper_staging_create_failed", errno: errno)
            }
            if created == 0 { try syncDirectory(directory.fd) }
            directory = try openChildDirectory(directory.fd, name: name)
            try requireOwnerAndPermissions(directory.fd, owner: context.stagingOwner, exactPrivate: true, rejectAllowACL: true)
        }
        return directory
    }

    static func validateApplication(at parent: Int32, name: String) throws {
        let app = try openChildDirectory(parent, name: name)
        do {
            let (metadataDirectory, wrapped) = try applicationMetadataDirectory(app)
            let plist = try readApplicationMetadata(metadataDirectory.fd)
            guard let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
                throw UninstallCoreFailure("helper_application_metadata_invalid")
            }
            let normalized = identifier.lowercased()
            guard !normalized.hasPrefix("com.apple."), !normalized.hasPrefix("com.macdefier.") else {
                throw UninstallCoreFailure("helper_protected_application")
            }
            if wrapped {
                guard plist["CFBundlePackageType"] as? String == "APPL",
                      plist["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"],
                      let executable = plist["CFBundleExecutable"] as? String,
                      isLeafName(executable) else {
                    throw UninstallCoreFailure("helper_application_metadata_invalid")
                }
                let executableIdentity = try identity(at: metadataDirectory.fd, name: executable)
                guard executableIdentity.kind == UInt32(S_IFREG) else {
                    throw UninstallCoreFailure("helper_application_metadata_invalid")
                }
            }
        } catch let failure as UninstallCoreFailure {
            // A missing file inside the package does not mean the selected app
            // is missing. Preserve this stage when reporting filesystem errors.
            if failure.code == "helper_open_failed" || failure.code == "helper_stat_failed" {
                throw UninstallCoreFailure("helper_application_metadata_unavailable", errno: failure.errno)
            }
            throw failure
        }
    }

    private static func applicationMetadataDirectory(_ app: DirectoryHandle) throws -> (DirectoryHandle, Bool) {
        var info = stat()
        if fstatat(app.fd, "Contents", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            // A present but unsafe Contents entry cannot fall back to another layout.
            return (try openChildDirectory(app.fd, name: "Contents"), false)
        }
        guard errno == ENOENT else {
            throw UninstallCoreFailure("helper_application_metadata_unavailable", errno: errno)
        }
        // App Store iPhone/iPad apps on Apple silicon have a flat inner bundle.
        // Read the link as data; never follow it or resolve an arbitrary path.
        var target = [UInt8](repeating: 0, count: 1024)
        let count = target.withUnsafeMutableBytes { readlinkat(app.fd, "WrappedBundle", $0.baseAddress!, $0.count) }
        guard count >= 0 else {
            throw UninstallCoreFailure("helper_application_metadata_unavailable", errno: errno)
        }
        guard count < target.count, let link = String(bytes: target.prefix(count), encoding: .utf8) else {
            throw UninstallCoreFailure("helper_application_metadata_invalid")
        }
        let components = link.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "Wrapper" else {
            throw UninstallCoreFailure("helper_application_metadata_invalid")
        }
        let leaf = String(components[1])
        guard isLeafName(leaf), leaf.count > 4, leaf.hasSuffix(".app") else {
            throw UninstallCoreFailure("helper_application_metadata_invalid")
        }
        let wrapper = try openChildDirectory(app.fd, name: "Wrapper")
        return (try openChildDirectory(wrapper.fd, name: leaf), true)
    }

    private static func isLeafName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 &&
        !name.contains("/") && !name.utf8.contains(0)
    }

    private static func readApplicationMetadata(_ directory: Int32) throws -> [String: Any] {
        let fd = openat(directory, "Info.plist", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UninstallCoreFailure("helper_application_metadata_unavailable", errno: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw UninstallCoreFailure("helper_stat_failed", errno: errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size > 0, info.st_size <= 1_048_576 else {
            throw UninstallCoreFailure("helper_application_metadata_invalid")
        }
        let length = Int(info.st_size)
        var bytes = [UInt8](repeating: 0, count: length)
        var offset = 0
        while offset < length {
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), length - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw UninstallCoreFailure("helper_application_metadata_unavailable", errno: count < 0 ? errno : nil) }
            offset += count
        }
        guard let plist = (try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil)) as? [String: Any] else {
            throw UninstallCoreFailure("helper_application_metadata_invalid")
        }
        return plist
    }
}

final class Transaction {
    let id: String
    let path: String
    let directory: DirectoryHandle
    private let request: UninstallRequest
    private let context: TrustedUninstallContext
    private let trashIdentity: UninstallFileIdentity?

    private init(id: String, path: String, directory: DirectoryHandle, request: UninstallRequest, context: TrustedUninstallContext,
                 trashIdentity: UninstallFileIdentity?) {
        self.id = id; self.path = path; self.directory = directory; self.request = request; self.context = context
        self.trashIdentity = trashIdentity
    }

    static func create(in staging: DirectoryHandle, context: TrustedUninstallContext, request: UninstallRequest,
                       trashIdentity: UninstallFileIdentity? = nil) throws -> Transaction {
        // A previously prepared request is not silently replayed after an unknown
        // outcome. Its journal must be inspected instead of making a new transaction.
        let id = request.requestID.uuidString
        guard mkdirat(staging.fd, id, 0o700) == 0 else { throw UninstallCoreFailure("helper_staging_create_failed", errno: errno) }
        let directory = try FileOperations.openChildDirectory(staging.fd, name: id)
        try FileOperations.requireOwnerAndPermissions(directory.fd, owner: context.stagingOwner, exactPrivate: true, rejectAllowACL: true)
        let path = context.stagingAnchor + "/" + context.serviceIdentifier + "/staging/" + id
        let transaction = Transaction(id: id, path: path, directory: directory, request: request, context: context, trashIdentity: trashIdentity)
        try transaction.record(state: "prepared")
        guard fsync(staging.fd) == 0 else { throw UninstallCoreFailure("helper_journal_sync_failed", errno: errno) }
        return transaction
    }

    func record(state: String, destinationName: String? = nil, reason: String? = nil) throws {
        struct Journal: Encodable {
            let version = 1
            let transactionID: String
            let request: UninstallRequest
            let userUID: UInt32
            let homeDirectory: String
            let originalTrashIdentity: UninstallFileIdentity?
            let state: String
            let destinationName: String?
            let reason: String?
        }
        let bytes = try JSONEncoder().encode(Journal(transactionID: id, request: request, userUID: context.userUID,
                                                     homeDirectory: context.homeDirectory, originalTrashIdentity: trashIdentity, state: state,
                                                     destinationName: destinationName, reason: reason))
        let temporaryName = "journal-\(UUID().uuidString).tmp"
        let fd = openat(directory.fd, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UninstallCoreFailure("helper_journal_write_failed", errno: errno) }
        defer { close(fd) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw UninstallCoreFailure("helper_journal_write_failed", errno: count < 0 ? errno : nil) }
            offset += count
        }
        guard fsync(fd) == 0 else { throw UninstallCoreFailure("helper_journal_sync_failed", errno: errno) }
        // Only replace our own protected journal; user objects always use RENAME_EXCL.
        guard renameat(directory.fd, temporaryName, directory.fd, "journal.json") == 0 else {
            throw UninstallCoreFailure("helper_journal_write_failed", errno: errno)
        }
        guard fsync(directory.fd) == 0 else { throw UninstallCoreFailure("helper_journal_sync_failed", errno: errno) }
    }
}
