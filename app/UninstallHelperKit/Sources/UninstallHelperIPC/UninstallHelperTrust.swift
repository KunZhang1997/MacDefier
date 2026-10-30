import Foundation
import Security

public struct UninstallHelperEndpoint: Sendable {
    public let serviceName: String
    public let clientIdentifier: String
    public let helperIdentifier: String
    public let teamIdentifier: String
    public var helloIdentity: String { serviceName + ":v2" }
    public var authorizationRightName: String { clientIdentifier + ".uninstall.trash.v2" }

    init(clientIdentifier: String, teamIdentifier: String) {
        self.clientIdentifier = clientIdentifier
        self.helperIdentifier = clientIdentifier + ".uninstall-helper"
        self.serviceName = self.helperIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public enum UninstallHelperTrust {
    public enum Role { case client, helper }

    /// Derive the expected peer from our own valid signature, not an environment
    /// variable or request. Unsigned and ad-hoc development builds fail closed.
    public static func current(role: Role) throws -> UninstallHelperEndpoint {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw UninstallHelperFailure("uninstall_helper_signature_invalid")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UninstallHelperFailure("uninstall_helper_signature_invalid")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0 else {
            throw UninstallHelperFailure("uninstall_helper_signature_invalid")
        }
        let clients = ["com.macdefier.app", "com.macdefier.app.dev"]
        guard let client = clients.first(where: { identifier == (role == .client ? $0 : $0 + ".uninstall-helper") }) else {
            throw UninstallHelperFailure("uninstall_helper_signature_invalid")
        }
        let expression = try requirement(teamIdentifier: team, identifier: identifier)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw UninstallHelperFailure("uninstall_helper_signature_invalid")
        }
        return UninstallHelperEndpoint(clientIdentifier: client, teamIdentifier: team)
    }

    public static func requirement(teamIdentifier: String, identifier: String) throws -> String {
        let identifiers = ["com.macdefier.app", "com.macdefier.app.dev",
                           "com.macdefier.app.uninstall-helper", "com.macdefier.app.dev.uninstall-helper"]
        guard teamIdentifier.utf8.count == 10,
              teamIdentifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              identifiers.contains(identifier) else {
            throw UninstallHelperFailure("uninstall_helper_signature_invalid")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Must be installed before activate/resume. The client must then complete a
    /// non-secret hello on this same connection before sending authorization data.
    public static func configureClient(_ connection: NSXPCConnection, endpoint: UninstallHelperEndpoint) throws {
        connection.setCodeSigningRequirement(try requirement(teamIdentifier: endpoint.teamIdentifier,
                                                            identifier: endpoint.helperIdentifier))
        connection.remoteObjectInterface = NSXPCInterface(with: UninstallHelperProtocol.self)
    }

    public static func configureListener(_ listener: NSXPCListener, endpoint: UninstallHelperEndpoint) throws {
        listener.setConnectionCodeSigningRequirement(try requirement(teamIdentifier: endpoint.teamIdentifier,
                                                                     identifier: endpoint.clientIdentifier))
    }

    public static func configureAcceptedConnection(_ connection: NSXPCConnection, endpoint: UninstallHelperEndpoint) throws {
        // Public message-level validation, not PID-based SecCode lookup. It is
        // repeated by XPC for subsequent messages, including after peer exec.
        connection.setCodeSigningRequirement(try requirement(teamIdentifier: endpoint.teamIdentifier,
                                                            identifier: endpoint.clientIdentifier))
        connection.exportedInterface = NSXPCInterface(with: UninstallHelperProtocol.self)
    }
}
