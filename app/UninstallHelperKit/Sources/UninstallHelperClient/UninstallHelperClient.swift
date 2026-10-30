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
    private var busy = false

    public func move(_ request: UninstallRequest) async throws -> UninstallResult {
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
        try await UninstallHelperSetup.prepare(endpoint)
        try Task.checkCancellation()
        let session = try HelperSession(endpoint: endpoint)
        defer { session.invalidate() }
        try await session.hello(endpoint)
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
        guard !busy else { throw UninstallHelperFailure("resource_mutation_busy") }
        busy = true
        defer { busy = false }
        let endpoint = try UninstallHelperTrust.current(role: .client)
        try await UninstallHelperSetup.prepare(endpoint)
        // Registration alone does not launch an on-demand service or verify
        // its version. Check the signed, non-secret hello before reporting
        // setup success; this neither requests authorization nor sends a move.
        try Task.checkCancellation()
        let session = try HelperSession(endpoint: endpoint)
        defer { session.invalidate() }
        try await session.hello(endpoint)
    }

    public func disable() async throws {
        guard !busy else { throw UninstallHelperFailure("resource_mutation_busy") }
        busy = true
        defer { busy = false }
        let endpoint = try UninstallHelperTrust.current(role: .client)
        try await UninstallHelperSetup.unregister(endpoint)
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
        let response: [String] = try await call(timeout: 8, failure: "uninstall_helper_unavailable") { proxy, finish in
            proxy.hello(challenge) { finish(.success([$0, $1])) }
        }
        if response == [challenge, endpoint.serviceName + ":v1"] {
            throw UninstallHelperFailure("uninstall_helper_update_required")
        }
        guard response == [challenge, endpoint.helloIdentity] else {
            throw UninstallHelperFailure("uninstall_helper_signature_invalid")
        }
    }

    func move(_ request: Data, authorization: Data) async throws -> UninstallResult {
        let data: Data = try await call(timeout: 30, failure: "uninstall_system_result_unknown") { proxy, finish in
            proxy.move(request, authorizationExternalForm: authorization) { data, code in
                if let code { finish(.failure(UninstallHelperFailure(code))) }
                else if let data, data.count <= 32_768 { finish(.success(data)) }
                else { finish(.failure(UninstallHelperFailure("uninstall_system_result_unknown"))) }
            }
        }
        do { return try JSONDecoder().decode(UninstallResult.self, from: data) }
        catch { throw UninstallHelperFailure("uninstall_system_result_unknown") }
    }

    private func call<Value>(timeout: TimeInterval, failure: String,
                             send: @escaping (UninstallHelperProtocol, @escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let once = ReplyOnce(continuation)
            let fail = { once.finish(.failure(UninstallHelperFailure(failure))) }
            stateQueue.async { [self] in
                guard !invalidated else { fail(); return }
                pendingFailure = fail
                once.startTimeout(after: timeout, failure: failure)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                    let detail = error as NSError
                    Self.log.error("XPC failure stage=\(failure, privacy: .public) domain=\(detail.domain, privacy: .public) code=\(detail.code, privacy: .public)")
                    self?.invalidate()
                    fail()
                }) as? UninstallHelperProtocol else {
                    fail(); return
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
    func startTimeout(after delay: TimeInterval, failure: String) {
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.failure(UninstallHelperFailure(failure)))
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
