import Darwin
import Foundation
import MachO
import UninstallHelperCore
import UninstallHelperIPC

/// Serializes bounded operations across clients. There is no Process/shell path.
private let operationQueue = DispatchQueue(label: "com.macdefier.uninstall-helper.operations")

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// On-demand MachService lifecycle: stays alive across active XPC connections and
/// in-flight Trash moves, then exits cleanly after an idle window (respecting
/// launchd's 10s MinimumRuntime throttle) so an app update never leaves an
/// unlinked helper binary permanently resident in memory.
private final class DaemonLifecycle: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macdefier.uninstall-helper.lifecycle")
    private let launchTime = DispatchTime.now()
    private let minimumUptimeSeconds: Double = 12
    private let normalIdleSeconds: Double = 30
    private let replacedBinaryIdleSeconds: Double = 1
    private let startupExecutable: (path: String, dev: dev_t, ino: ino_t)?
    private weak var listener: NSXPCListener?
    private var activeConnections = 0
    private var activeOperations = 0
    private var idleWorkItem: DispatchWorkItem?
    private var exiting = false

    init() {
        self.startupExecutable = Self.captureOwnExecutable()
    }

    func startMonitoring(listener: NSXPCListener) {
        queue.async { [self] in
            self.listener = listener
            scheduleIdleExitLocked()
        }
    }

    func connectionOpened() -> Bool {
        queue.sync {
            guard !exiting else { return false }
            activeConnections += 1
            idleWorkItem?.cancel()
            idleWorkItem = nil
            return true
        }
    }

    func connectionClosed() {
        queue.async { [self] in
            activeConnections = max(0, activeConnections - 1)
            scheduleIdleExitLocked()
        }
    }

    func operationStarted() -> Bool {
        queue.sync {
            guard !exiting else { return false }
            activeOperations += 1
            idleWorkItem?.cancel()
            idleWorkItem = nil
            return true
        }
    }

    func operationFinished() {
        queue.async { [self] in
            activeOperations = max(0, activeOperations - 1)
            scheduleIdleExitLocked()
        }
    }

    private func scheduleIdleExitLocked() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
        guard !exiting, activeConnections == 0, activeOperations == 0 else { return }
        let idleSeconds = isExecutableReplacedOnDisk() ? replacedBinaryIdleSeconds : normalIdleSeconds
        let earliestExit = launchTime + minimumUptimeSeconds
        let desiredExit = DispatchTime.now() + idleSeconds
        let deadline = desiredExit > earliestExit ? desiredExit : earliestExit
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.exiting, self.activeConnections == 0, self.activeOperations == 0 else { return }
            self.exiting = true
            self.listener?.suspend()
            exit(EXIT_SUCCESS)
        }
        idleWorkItem = work
        queue.asyncAfter(deadline: deadline, execute: work)
    }

    private func isExecutableReplacedOnDisk() -> Bool {
        guard let startup = startupExecutable else { return false }
        var st = stat()
        guard lstat(startup.path, &st) == 0 else { return true }
        return st.st_dev != startup.dev || st.st_ino != startup.ino
    }

    private static func captureOwnExecutable() -> (path: String, dev: dev_t, ino: ino_t)? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0,
              let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (path, st.st_dev, st.st_ino)
    }
}

private final class Session: NSObject, UninstallHelperProtocol {
    private weak var connection: NSXPCConnection?
    private let endpoint: UninstallHelperEndpoint
    private let caller: UninstallHelperCaller
    private let lifecycle: DaemonLifecycle
    // NSXPC serializes incoming calls for this exported object.
    private var greeted = false
    private var consumed = false

    init(connection: NSXPCConnection, endpoint: UninstallHelperEndpoint,
         caller: UninstallHelperCaller, lifecycle: DaemonLifecycle) {
        self.connection = connection
        self.endpoint = endpoint
        self.caller = caller
        self.lifecycle = lifecycle
    }

    func hello(_ challenge: String, reply: @escaping (String, String) -> Void) {
        guard currentConnectionMatches(), !consumed,
              UninstallHelperLimits.isValidChallenge(challenge) else { reply("", ""); return }
        greeted = true
        reply(challenge, endpoint.helloIdentity)
    }

    func move(_ requestData: Data, authorizationExternalForm: Data,
              reply: @escaping (Data?, String?) -> Void) {
        guard currentConnectionMatches(), greeted, !consumed else {
            reply(nil, "uninstall_helper_connection_invalid"); return
        }
        consumed = true
        guard !requestData.isEmpty, requestData.count <= UninstallHelperLimits.maximumRequestBytes,
              authorizationExternalForm.count == UninstallHelperAuthorization.externalFormLength else {
            reply(nil, "uninstall_helper_request_invalid"); return
        }
        guard lifecycle.operationStarted() else {
            reply(nil, "uninstall_helper_unavailable"); return
        }
        let lifecycle = self.lifecycle
        operationQueue.async { [caller, endpoint] in
            defer { lifecycle.operationFinished() }
            do {
                let request = try JSONDecoder().decode(UninstallRequest.self, from: requestData)
                try UninstallHelperAuthorization.verifyExternalForm(authorizationExternalForm, endpoint: endpoint)
                let context = try TrustedUninstallContext.production(userUID: caller.userUID,
                    homeDirectory: caller.homeDirectory, serviceIdentifier: endpoint.serviceName)
                let result = UninstallEngine.moveToTrash(request: request, context: context)
                reply(try JSONEncoder().encode(result), nil)
            } catch let failure as UninstallHelperFailure {
                reply(nil, failure.code)
            } catch {
                reply(nil, "uninstall_helper_request_invalid")
            }
        }
    }

    private func currentConnectionMatches() -> Bool {
        guard let connection, let current = NSXPCConnection.current() else { return false }
        return current === connection && current.effectiveUserIdentifier == caller.userUID
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let endpoint: UninstallHelperEndpoint
    let lifecycle: DaemonLifecycle
    init(endpoint: UninstallHelperEndpoint, lifecycle: DaemonLifecycle) {
        self.endpoint = endpoint
        self.lifecycle = lifecycle
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try UninstallHelperTrust.configureAcceptedConnection(connection, endpoint: endpoint)
            let caller = try UninstallHelperCaller.from(connection)
            guard lifecycle.connectionOpened() else { return false }
            let closeOnce = OnceFlag()
            let lifecycle = self.lifecycle
            let markClosed = {
                if closeOnce.tryFire() { lifecycle.connectionClosed() }
            }
            connection.interruptionHandler = { [weak connection] in
                connection?.invalidate()
                markClosed()
            }
            connection.invalidationHandler = {
                markClosed()
            }
            connection.exportedObject = Session(connection: connection, endpoint: endpoint,
                                                caller: caller, lifecycle: lifecycle)
            connection.resume()
            return true
        } catch { return false }
    }
}

do {
    guard geteuid() == 0 else { throw UninstallHelperFailure("uninstall_helper_root_required") }
    let endpoint = try UninstallHelperTrust.current(role: .helper)
    try UninstallHelperAuthorization.ensureRightDefinition(endpoint: endpoint)
    let lifecycle = DaemonLifecycle()
    let listener = NSXPCListener(machServiceName: endpoint.serviceName)
    try UninstallHelperTrust.configureListener(listener, endpoint: endpoint)
    let delegate = ListenerDelegate(endpoint: endpoint, lifecycle: lifecycle)
    listener.delegate = delegate
    listener.resume()
    lifecycle.startMonitoring(listener: listener)
    withExtendedLifetime((listener, delegate, lifecycle)) { dispatchMain() }
} catch let failure as UninstallHelperFailure {
    fputs(failure.code + "\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("uninstall_helper_start_failed\n", stderr)
    exit(EXIT_FAILURE)
}
