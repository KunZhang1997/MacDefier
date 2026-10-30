import Darwin
import Foundation

public struct UninstallFileIdentity: Codable, Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64
    public let kind: UInt32
    public let owner: UInt32
    public init(device: Int64, inode: UInt64, kind: UInt32, owner: UInt32) {
        self.device = device; self.inode = inode; self.kind = kind; self.owner = owner
    }
    init(_ value: stat) {
        self.init(device: Int64(value.st_dev), inode: UInt64(value.st_ino),
                  kind: UInt32(value.st_mode & mode_t(S_IFMT)), owner: value.st_uid)
    }
}

/// Destination, uid, home and staging policy never come from this IPC payload.
public struct UninstallRequest: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let sourcePath: String
    public let expectedItem: UninstallFileIdentity
    public let expectedParent: UninstallFileIdentity
    public init(requestID: UUID = UUID(), sourcePath: String, expectedItem: UninstallFileIdentity, expectedParent: UninstallFileIdentity) {
        self.requestID = requestID; self.sourcePath = sourcePath; self.expectedItem = expectedItem; self.expectedParent = expectedParent
    }
}

public struct UninstallResult: Codable, Sendable, Equatable {
    public enum Disposition: String, Codable, Sendable {
        case moved, rejected, recoveredOriginal, retainedStaging
        /// Rename committed, but its public destination/durable receipt cannot be verified.
        /// Never roll back or continue associated-data cleanup in this state.
        case committedUnknown
    }
    public let disposition: Disposition
    public let requestID: UUID
    public let reason: String?
    public let sourcePath: String
    public let destinationPath: String?
    /// Retained staging is root-only; this is a support/recovery address, not a Finder link.
    public let recoveryPath: String?
    public let journalPath: String?
    public let transactionID: String?
    public let errno: Int32?

    public init(disposition: Disposition, requestID: UUID, sourcePath: String, reason: String? = nil,
                destinationPath: String? = nil, recoveryPath: String? = nil, journalPath: String? = nil,
                transactionID: String? = nil, errno: Int32? = nil) {
        self.disposition = disposition; self.requestID = requestID; self.sourcePath = sourcePath; self.reason = reason
        self.destinationPath = destinationPath; self.recoveryPath = recoveryPath; self.journalPath = journalPath
        self.transactionID = transactionID; self.errno = errno
    }
}

/// Server-only, deliberately not Codable. No client-selected destination or user identity.
public struct TrustedUninstallContext: Sendable {
    let userUID: UInt32
    let homeDirectory: String
    let applicationsDirectory: String
    let stagingAnchor: String
    let serviceIdentifier: String
    let stagingOwner: UInt32
    let requireRootAncestors: Bool

    public static func production(userUID: UInt32, homeDirectory: String, serviceIdentifier: String) throws -> Self {
        guard geteuid() == 0, userUID != 0,
              ["com.macdefier.app.uninstall-helper", "com.macdefier.app.dev.uninstall-helper"].contains(serviceIdentifier),
              FileOperations.isAbsoluteNormalized(homeDirectory), homeDirectory != "/" else {
            throw UninstallCoreFailure("helper_invalid_context")
        }
        return Self(userUID: userUID, homeDirectory: homeDirectory, applicationsDirectory: "/Applications",
                    stagingAnchor: "/Library/Application Support", serviceIdentifier: serviceIdentifier,
                    stagingOwner: 0, requireRootAncestors: true)
    }

    /// Only @testable clients can inject non-production roots and an unprivileged owner.
    static func fixture(userUID: UInt32, homeDirectory: String, applicationsDirectory: String, stagingAnchor: String) -> Self {
        Self(userUID: userUID, homeDirectory: homeDirectory, applicationsDirectory: applicationsDirectory,
             stagingAnchor: stagingAnchor, serviceIdentifier: "fixture-helper", stagingOwner: geteuid(), requireRootAncestors: false)
    }
}

public struct UninstallCoreFailure: Error, LocalizedError, Sendable {
    public let code: String
    public let errno: Int32?
    init(_ code: String, errno: Int32? = nil) { self.code = code; self.errno = errno }
    public var errorDescription: String? { code }
}

public enum UninstallEngine {
    /// Local read-only preview capture, not an authorization or an IPC operation.
    public static func captureRequest(sourcePath: String) throws -> UninstallRequest {
        guard FileOperations.isAbsoluteNormalized(sourcePath), sourcePath != "/" else {
            throw UninstallCoreFailure("helper_source_path_rejected")
        }
        let parent = try FileOperations.openDirectory((sourcePath as NSString).deletingLastPathComponent)
        return UninstallRequest(sourcePath: sourcePath,
                                expectedItem: try FileOperations.identity(at: parent.fd, name: (sourcePath as NSString).lastPathComponent),
                                expectedParent: try parent.identity())
    }

    public static func moveToTrash(request: UninstallRequest, context: TrustedUninstallContext) -> UninstallResult {
        moveToTrash(request: request, context: context, hooks: Hooks())
    }

    /// Test-only race injection; not public and not serializable by the IPC caller.
    struct Hooks {
        var beforeCapture: (() throws -> Void)?
        var afterCapture: (() throws -> Void)?
        var beforeCommit: (() throws -> Void)?
        var immediatelyBeforeCommitRename: (() throws -> Void)?
    }

    static func moveToTrash(request: UninstallRequest, context: TrustedUninstallContext, hooks: Hooks) -> UninstallResult {
        var transaction: Transaction?
        var sourceParent: DirectoryHandle?
        var captured = false
        var committed = false
        var destinationPath: String?
        do {
            guard geteuid() == context.stagingOwner else { throw UninstallCoreFailure("helper_invalid_context") }
            let name = try validateScope(request, context: context)
            let parent = try FileOperations.openDirectory(context.applicationsDirectory)
            sourceParent = parent
            guard try parent.identity() == request.expectedParent else { throw UninstallCoreFailure("helper_source_parent_changed") }
            let before = try FileOperations.identity(at: parent.fd, name: name)
            guard before == request.expectedItem else { throw UninstallCoreFailure("helper_source_identity_changed") }
            try FileOperations.validateApplication(at: parent.fd, name: name)

            let home = try FileOperations.openDirectory(context.homeDirectory)
            let homeIdentity = try home.identity()
            try FileOperations.requireOwnerAndPermissions(home.fd, owner: context.userUID)
            // No root mkdir/chown/chmod in a user-writable home. Missing Trash is a refusal.
            let trash = try FileOperations.openChildDirectory(home.fd, name: ".Trash")
            let trashIdentity = try trash.identity()
            try FileOperations.requireOwnerAndPermissions(trash.fd, owner: context.userUID)
            let staging = try FileOperations.prepareStaging(context)
            guard before.device == trashIdentity.device, before.device == (try staging.identity()).device else {
                throw UninstallCoreFailure("helper_cross_volume")
            }
            let active = try Transaction.create(in: staging, context: context, request: request, trashIdentity: trashIdentity)
            transaction = active
            try hooks.beforeCapture?()
            try FileOperations.requireBinding(path: context.applicationsDirectory, identity: request.expectedParent)
            // Pre-rename stat is not sufficient. Claim first, then verify the actual
            // entry inside root-only staging before it can enter the user's Trash.
            try FileOperations.renameExclusive(from: parent.fd, name: name, to: active.directory.fd, newName: "item")
            captured = true
            try FileOperations.syncDirectory(parent.fd)
            try FileOperations.syncDirectory(active.directory.fd)
            try hooks.afterCapture?()
            guard try FileOperations.identity(at: active.directory.fd, name: "item") == request.expectedItem else {
                throw UninstallCoreFailure("helper_source_identity_changed")
            }
            try FileOperations.validateApplication(at: active.directory.fd, name: "item")
            try active.record(state: "captured")
            try hooks.beforeCommit?()
            try FileOperations.requireBinding(path: context.applicationsDirectory, identity: request.expectedParent)
            try FileOperations.requireBinding(path: context.homeDirectory, identity: homeIdentity)
            try FileOperations.requireBinding(path: context.homeDirectory + "/.Trash", identity: trashIdentity)
            try FileOperations.requireOwnerAndPermissions(trash.fd, owner: context.userUID)
            guard try FileOperations.identity(at: active.directory.fd, name: "item") == request.expectedItem else {
                throw UninstallCoreFailure("helper_staged_identity_changed")
            }
            guard FileOperations.isMissing(at: parent.fd, name: name) else { throw UninstallCoreFailure("helper_source_reappeared") }
            for attempt in 0..<32 {
                let targetName = attempt == 0 ? name : "\(name).\(UUID().uuidString)"
                try active.record(state: "committing", destinationName: targetName)
                try FileOperations.requireBinding(path: context.applicationsDirectory, identity: request.expectedParent)
                try FileOperations.requireBinding(path: context.homeDirectory, identity: homeIdentity)
                try FileOperations.requireBinding(path: context.homeDirectory + "/.Trash", identity: trashIdentity)
                guard FileOperations.isMissing(at: parent.fd, name: name) else { throw UninstallCoreFailure("helper_source_reappeared") }
                do {
                    try hooks.immediatelyBeforeCommitRename?()
                    try FileOperations.renameExclusive(from: active.directory.fd, name: "item", to: trash.fd, newName: targetName)
                    committed = true
                    destinationPath = context.homeDirectory + "/.Trash/" + targetName
                    // Directory binding checks and rename cannot be one syscall.
                    // Detect this final window after commit, without ever moving a
                    // user-owned Trash entry again in an attempted rollback.
                    try FileOperations.requireBinding(path: context.applicationsDirectory, identity: request.expectedParent)
                    try FileOperations.requireBinding(path: context.homeDirectory, identity: homeIdentity)
                    try FileOperations.requireBinding(path: context.homeDirectory + "/.Trash", identity: trashIdentity)
                    guard try FileOperations.identity(at: trash.fd, name: targetName) == request.expectedItem else {
                        throw UninstallCoreFailure("helper_commit_destination_changed")
                    }
                    guard FileOperations.isMissing(at: parent.fd, name: name) else { throw UninstallCoreFailure("helper_source_reappeared") }
                    try FileOperations.syncDirectory(trash.fd)
                    try FileOperations.syncDirectory(active.directory.fd)
                    break
                } catch let error as UninstallCoreFailure where error.errno == EEXIST { continue }
            }
            guard committed else { throw UninstallCoreFailure("helper_trash_collision_limit") }
            try active.record(state: "moved", destinationName: destinationPath.map { ($0 as NSString).lastPathComponent })
            return result(.moved, request, active, destination: destinationPath)
        } catch {
            if committed {
                try? transaction?.record(state: "committed_unknown", destinationName: destinationPath.map { ($0 as NSString).lastPathComponent },
                                         reason: failureCode(error))
                return result(.committedUnknown, request, transaction, error: error)
            }
            guard captured, let transaction, let sourceParent else {
                try? transaction?.record(state: "rejected", reason: failureCode(error))
                return result(.rejected, request, transaction, error: error)
            }
            return rollback(transaction, request: request, context: context, sourceParent: sourceParent, cause: error)
        }
    }

    private static func validateScope(_ request: UninstallRequest, context: TrustedUninstallContext) throws -> String {
        guard FileOperations.isAbsoluteNormalized(request.sourcePath),
              (request.sourcePath as NSString).deletingLastPathComponent == context.applicationsDirectory,
              request.expectedItem.kind == UInt32(S_IFDIR), request.expectedParent.kind == UInt32(S_IFDIR) else {
            throw UninstallCoreFailure("helper_source_path_rejected")
        }
        let name = (request.sourcePath as NSString).lastPathComponent
        guard name.hasSuffix(".app"), name.count > 4, !name.lowercased().hasPrefix("macdefier") else {
            throw UninstallCoreFailure("helper_protected_application")
        }
        return name
    }

    private static func rollback(_ transaction: Transaction, request: UninstallRequest, context: TrustedUninstallContext,
                                 sourceParent: DirectoryHandle, cause: Error) -> UninstallResult {
        do {
            try FileOperations.requireBinding(path: context.applicationsDirectory, identity: request.expectedParent)
            try FileOperations.renameExclusive(from: transaction.directory.fd, name: "item", to: sourceParent.fd,
                                               newName: (request.sourcePath as NSString).lastPathComponent)
            try? FileOperations.syncDirectory(sourceParent.fd)
            try? FileOperations.syncDirectory(transaction.directory.fd)
            try? transaction.record(state: "recovered_original", reason: failureCode(cause))
            return result(.recoveredOriginal, request, transaction, error: cause)
        } catch {
            try? transaction.record(state: "retained_staging", reason: failureCode(cause))
            return result(.retainedStaging, request, transaction, reason: failureCode(cause), recovery: transaction.path + "/item", error: error)
        }
    }

    private static func failureCode(_ error: Error) -> String { (error as? UninstallCoreFailure)?.code ?? "helper_operation_failed" }
    private static func result(_ disposition: UninstallResult.Disposition, _ request: UninstallRequest, _ transaction: Transaction?,
                               reason: String? = nil, destination: String? = nil, recovery: String? = nil, error: Error? = nil) -> UninstallResult {
        UninstallResult(disposition: disposition, requestID: request.requestID, sourcePath: request.sourcePath, reason: reason ?? error.map(failureCode),
                        destinationPath: destination, recoveryPath: recovery, journalPath: transaction.map { $0.path + "/journal.json" },
                        transactionID: transaction?.id, errno: (error as? UninstallCoreFailure)?.errno)
    }
}
