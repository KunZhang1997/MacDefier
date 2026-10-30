import Darwin
import Foundation

public struct UninstallHelperCaller: Sendable {
    public let userUID: UInt32
    public let homeDirectory: String

    /// Called only after the listener has accepted the peer's code requirement.
    /// Identity comes from the kernel-backed connection, never request fields.
    public static func from(_ connection: NSXPCConnection) throws -> Self {
        try resolve(userUID: connection.effectiveUserIdentifier)
    }

    static func resolve(userUID: uid_t) throws -> Self {
        guard userUID != 0, userUID != uid_t.max else { throw invalidCaller() }
        var bufferSize = 16_384
        while bufferSize <= 1_048_576 {
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let value: (Int32, String?) = buffer.withUnsafeMutableBufferPointer { storage in
                let status = getpwuid_r(userUID, &entry, storage.baseAddress!, storage.count, &result)
                guard status == 0, result != nil, entry.pw_uid == userUID, let directory = entry.pw_dir else {
                    return (status, nil)
                }
                return (status, String(validatingUTF8: directory))
            }
            if value.0 == ERANGE { bufferSize *= 2; continue }
            guard value.0 == 0, let home = value.1 else { throw invalidCaller() }
            try validateHome(home, userUID: userUID)
            return Self(userUID: userUID, homeDirectory: home)
        }
        throw invalidCaller()
    }

    static func validateHome(_ home: String, userUID: uid_t) throws {
        guard home.hasPrefix("/"), home != "/", !home.hasPrefix("//"),
              !home.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              home.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }),
              let resolved = realpath(home, nil) else { throw invalidCaller() }
        defer { free(resolved) }
        guard String(cString: resolved) == home else { throw invalidCaller() }
        let descriptor = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalidCaller() }
        defer { close(descriptor) }
        var info = stat()
        var filesystem = statfs()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == userUID, info.st_mode & 0o002 == 0,
              fstatfs(descriptor, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw invalidCaller()
        }
    }

    private static func invalidCaller() -> UninstallHelperFailure {
        UninstallHelperFailure("uninstall_helper_caller_invalid")
    }
}
