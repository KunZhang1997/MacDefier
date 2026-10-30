import Darwin
import Foundation
import UninstallHelperCore
import UninstallHelperIPC

/// Serializes bounded operations across clients. There is no Process/shell path.
private let operationQueue = DispatchQueue(label: "com.macdefier.uninstall-helper.operations")

private final class Session: NSObject, UninstallHelperProtocol {
    private weak var connection: NSXPCConnection?
    private let endpoint: UninstallHelperEndpoint
    private let caller: UninstallHelperCaller
    // NSXPC serializes incoming calls for this exported object.
    private var greeted = false
    private var consumed = false

    init(connection: NSXPCConnection, endpoint: UninstallHelperEndpoint, caller: UninstallHelperCaller) {
        self.connection = connection
        self.endpoint = endpoint
        self.caller = caller
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
        operationQueue.async { [caller, endpoint] in
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
    init(endpoint: UninstallHelperEndpoint) { self.endpoint = endpoint }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try UninstallHelperTrust.configureAcceptedConnection(connection, endpoint: endpoint)
            let caller = try UninstallHelperCaller.from(connection)
            connection.exportedObject = Session(connection: connection, endpoint: endpoint, caller: caller)
            connection.resume()
            return true
        } catch { return false }
    }
}

do {
    guard geteuid() == 0 else { throw UninstallHelperFailure("uninstall_helper_root_required") }
    let endpoint = try UninstallHelperTrust.current(role: .helper)
    try UninstallHelperAuthorization.ensureRightDefinition(endpoint: endpoint)
    let listener = NSXPCListener(machServiceName: endpoint.serviceName)
    try UninstallHelperTrust.configureListener(listener, endpoint: endpoint)
    let delegate = ListenerDelegate(endpoint: endpoint)
    listener.delegate = delegate
    listener.resume()
    withExtendedLifetime((listener, delegate)) { dispatchMain() }
} catch let failure as UninstallHelperFailure {
    fputs(failure.code + "\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("uninstall_helper_start_failed\n", stderr)
    exit(EXIT_FAILURE)
}
