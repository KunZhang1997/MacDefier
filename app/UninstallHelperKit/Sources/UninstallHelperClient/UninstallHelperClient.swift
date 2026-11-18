import AppKit
import Darwin
import Foundation
import ServiceManagement
import OSLog
import UninstallHelperCore
import UninstallHelperIPC

/// This actor never elevates a shell or an arbitrary cleanup path. The caller
/// supplies the frozen preview identity; the service independently checks scope.
public actor UninstallHelperClient {
    public static let shared = UninstallHelperClient()
    private static let log = Logger(subsystem: "com.macdefier.app", category: "uninstall-helper-client")
    private var busy = false
    private var syncTask: Task<Void, Never>?

    /// Proactively sync an already-enabled SMAppService registration if the
    /// bundled helper binary changed on disk (rebuild, reinstall or Sparkle update).
    public func synchronizeRegistrationIfNeeded() async {
        if let existing = syncTask {
            await existing.value
            return
        }
        guard !busy else { return }
        let task = Task { @MainActor in
            guard let endpoint = try? UninstallHelperTrust.current(role: .client) else { return }
            await UninstallHelperSetup.synchronizeEnabledRegistrationIfNeeded(endpoint)
        }
        syncTask = task
        await task.value
        syncTask = nil
    }

    public func move(_ request: UninstallRequest) async throws -> UninstallResult {
        if let pendingSync = syncTask { await pendingSync.value }
        guard !busy else { throw UninstallHelperFailure("resource_mutation_busy") }
        busy = true
        defer { busy = false }
        let endpoint = try UninstallHelperTrust.current(role: .client)
        guard (request.sourcePath as NSString).deletingLastPathComponent == "/Applications",
              request.sourcePath.hasSuffix(".app") else {
            throw UninstallHelperFailure("uninstall_helper_scope_rejected")
        }
        // Keep the original inode allocated across an arbitrarily long system
        // authorization dialog. Never adopt a fresh snapshot after that dialog.
        let held = try HeldSource(request)
        defer { held.close() }
        let session = try await openVerifiedSession(endpoint: endpoint)
        defer { session.invalidate() }
        let authorization = try await Task.detached(priority: .userInitiated) {
            try UninstallHelperAuthorization.requestExternalForm(endpoint: endpoint)
        }.value
        defer { authorization.finish() }
        try Task.checkCancellation()
        try held.validate(request)
        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= UninstallHelperLimits.maximumRequestBytes else {
            throw UninstallHelperFailure("uninstall_helper_scope_rejected")
        }
        // Exactly one send, on the connection whose hello was verified. A lost
        // reply is not a cancellation and must never trigger an automatic retry.
        let result = try await session.move(encoded, authorization: authorization.externalForm)
        guard result.sourcePath == request.sourcePath, result.requestID == request.requestID else {
            throw UninstallHelperFailure("uninstall_system_result_unknown")
        }
        return result
    }

    public func enable() async throws {
        if let pendingSync = syncTask { await pendingSync.value }
        guard !busy else { throw UninstallHelperFailure("resource_mutation_busy") }
        busy = true
        defer { busy = false }
        let endpoint = try UninstallHelperTrust.current(role: .client)
        // Registration alone does not launch an on-demand service or verify
        // its version. Check the signed, non-secret hello before reporting
        // setup success; this neither requests authorization nor sends a move.
        let session = try await openVerifiedSession(endpoint: endpoint)
        session.invalidate()
    }

    public func disable() async throws {
        if let pendingSync = syncTask { await pendingSync.value }
        guard !busy else { throw UninstallHelperFailure("resource_mutation_busy") }
        busy = true
        defer { busy = false }
        let endpoint = try UninstallHelperTrust.current(role: .client)
        try await UninstallHelperSetup.unregister(endpoint)
    }

    private func openVerifiedSession(endpoint: UninstallHelperEndpoint) async throws -> HelperSession {
        try await Self.establishVerifiedSession(
            prepare: {
                try await UninstallHelperSetup.prepare(endpoint)
            },
            openAndGreet: {
                try Task.checkCancellation()
                let session = try HelperSession(endpoint: endpoint)
                do {
                    try await session.hello(endpoint)
                    return session
                } catch {
                    session.invalidate()
                    throw error
                }
            },
            reinstall: {
                Self.log.warning("hello handshake failed on enabled service; cycling SMAppService registration once")
                try await UninstallHelperSetup.reinstallRegistration(endpoint)
            },
            sleepMilliseconds: { ms in
                try await Task.sleep(nanoseconds: ms * 1_000_000)
            }
        )
    }

    static func establishVerifiedSession<Session>(
        prepare: () async throws -> Void,
        openAndGreet: () async throws -> Session,
        reinstall: () async throws -> Void,
        sleepMilliseconds: (UInt64) async throws -> Void
    ) async throws -> Session {
        try await prepare()
        try Task.checkCancellation()
        do {
            return try await attemptGreet(maxTransientRetries: 1, openAndGreet: openAndGreet,
                                          sleepMilliseconds: sleepMilliseconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as UninstallHelperFailure {
            throw failure
        } catch is HelperHandshakeError {
            try Task.checkCancellation()
            try await reinstall()
            try Task.checkCancellation()
            do {
                return try await attemptGreet(maxTransientRetries: 2, openAndGreet: openAndGreet,
                                              sleepMilliseconds: sleepMilliseconds)
            } catch let retryHandshake as HelperHandshakeError {
                throw retryHandshake.publicFailure
            }
        }
    }

    private static func attemptGreet<Session>(
        maxTransientRetries: Int,
        openAndGreet: () async throws -> Session,
        sleepMilliseconds: (UInt64) async throws -> Void
    ) async throws -> Session {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await openAndGreet()
            } catch let handshake as HelperHandshakeError where handshake.isTransientBootstrapFailure && attempt < maxTransientRetries {
                attempt += 1
                let delayMs = UInt64(attempt * 150)
                try await sleepMilliseconds(delayMs)
            }
        }
    }
}

enum HelperHandshakeError: Error, Equatable, Sendable {
    case xpcFailure(domain: String, code: Int)
    case timedOut
    case invalidated
    case protocolMismatch(String)

    var publicFailure: UninstallHelperFailure {
        switch self {
        case .protocolMismatch(let code):
            return UninstallHelperFailure(code)
        case .xpcFailure, .timedOut, .invalidated:
            return UninstallHelperFailure("uninstall_helper_unavailable")
        }
    }

    var isTransientBootstrapFailure: Bool {
        guard case let .xpcFailure(domain, code) = self else { return false }
        return domain == NSCocoaErrorDomain && (code == 4097 || code == 4099)
    }
}

private final class HeldSource {
    private var fd: Int32
    init(_ request: UninstallRequest) throws {
        fd = open(request.sourcePath, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UninstallHelperFailure("uninstall_identity_changed") }
        do { try validate(request) } catch { close(); throw error }
    }
    func validate(_ request: UninstallRequest) throws {
        var value = stat()
        guard fd >= 0, fstat(fd, &value) == 0,
              UninstallFileIdentity(device: Int64(value.st_dev), inode: UInt64(value.st_ino),
                                    kind: UInt32(value.st_mode & mode_t(S_IFMT)), owner: value.st_uid) == request.expectedItem else {
            throw UninstallHelperFailure("uninstall_identity_changed")
        }
        let fresh = try UninstallEngine.captureRequest(sourcePath: request.sourcePath)
        guard fresh.expectedItem == request.expectedItem, fresh.expectedParent == request.expectedParent else {
            throw UninstallHelperFailure("uninstall_identity_changed")
        }
    }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }
}

private final class HelperSession: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.macdefier.app", category: "uninstall-helper-connection")
    private let connection: NSXPCConnection
    private let stateQueue = DispatchQueue(label: "com.macdefier.uninstall-helper.client-session")
    private var invalidated = false
    private var pendingFailure: (() -> Void)?
    init(endpoint: UninstallHelperEndpoint) throws {
        connection = NSXPCConnection(machServiceName: endpoint.serviceName, options: .privileged)
        try UninstallHelperTrust.configureClient(connection, endpoint: endpoint)
        connection.interruptionHandler = { [weak self] in self?.invalidate() }
        connection.invalidationHandler = { [weak self] in self?.invalidate() }
        connection.resume()
    }
    func invalidate() {
        stateQueue.async { [self] in
            guard !invalidated else { return }
            invalidated = true
            let failure = pendingFailure
            pendingFailure = nil
            // Serialize invalidation with the check-and-send below. Callbacks
            // enqueue asynchronously, so Foundation reentrancy cannot deadlock
            // a held lock. This session never reconnects after interruption.
            connection.invalidate()
            failure?()
        }
    }

    func hello(_ endpoint: UninstallHelperEndpoint) async throws {
        let challenge = UUID().uuidString
        let response: [String] = try await call(
            timeout: 8,
            stage: "uninstall_helper_unavailable",
            invalidatedError: { HelperHandshakeError.invalidated },
            timeoutError: { HelperHandshakeError.timedOut },
            xpcError: { HelperHandshakeError.xpcFailure(domain: $0.domain, code: $0.code) }
        ) { proxy, finish in
            proxy.hello(challenge) { finish(.success([$0, $1])) }
        }
        if response == [challenge, endpoint.serviceName + ":v1"] {
            throw HelperHandshakeError.protocolMismatch("uninstall_helper_update_required")
        }
        guard response == [challenge, endpoint.helloIdentity] else {
            throw HelperHandshakeError.protocolMismatch("uninstall_helper_signature_invalid")
        }
    }

    func move(_ request: Data, authorization: Data) async throws -> UninstallResult {
        let unknown: @Sendable () -> Error = { UninstallHelperFailure("uninstall_system_result_unknown") }
        let data: Data = try await call(
            timeout: 30,
            stage: "uninstall_system_result_unknown",
            invalidatedError: unknown,
            timeoutError: unknown,
            xpcError: { _ in unknown() }
        ) { proxy, finish in
            proxy.move(request, authorizationExternalForm: authorization) { data, code in
                if let code { finish(.failure(UninstallHelperFailure(code))) }
                else if let data, data.count <= 32_768 { finish(.success(data)) }
                else { finish(.failure(UninstallHelperFailure("uninstall_system_result_unknown"))) }
            }
        }
        do { return try JSONDecoder().decode(UninstallResult.self, from: data) }
        catch { throw UninstallHelperFailure("uninstall_system_result_unknown") }
    }

    private func call<Value>(timeout: TimeInterval,
                             stage: String,
                             invalidatedError: @escaping @Sendable () -> Error,
                             timeoutError: @escaping @Sendable () -> Error,
                             xpcError: @escaping @Sendable (NSError) -> Error,
                             send: @escaping (UninstallHelperProtocol, @escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let once = ReplyOnce(continuation)
            let failInvalidated = { once.finish(.failure(invalidatedError())) }
            stateQueue.async { [self] in
                guard !invalidated else { failInvalidated(); return }
                pendingFailure = failInvalidated
                once.startTimeout(after: timeout, timeoutError: timeoutError)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                    let detail = error as NSError
                    Self.log.error("XPC failure stage=\(stage, privacy: .public) domain=\(detail.domain, privacy: .public) code=\(detail.code, privacy: .public)")
                    once.finish(.failure(xpcError(detail)))
                    self?.invalidate()
                }) as? UninstallHelperProtocol else {
                    failInvalidated(); return
                }
                send(proxy) { once.finish($0) }
            }
        }
    }
}

private final class ReplyOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: DispatchWorkItem?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func startTimeout(after delay: TimeInterval, timeoutError: @escaping @Sendable () -> Error) {
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.failure(timeoutError()))
        }
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        self.timer = timer
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: timer)
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let timeout = timer
        timer = nil
        lock.unlock()
        guard let pending else { return }
        timeout?.cancel()
        pending.resume(with: result)
    }
}
