import Darwin
import Foundation
import Security
import OSLog

public final class UninstallAuthorizationHandle: @unchecked Sendable {
    public let externalForm: Data
    private let lock = NSLock()
    private var reference: AuthorizationRef?

    init(reference: AuthorizationRef, externalForm: Data) {
        self.reference = reference
        self.externalForm = externalForm
    }

    public func finish() {
        lock.lock()
        let reference = self.reference
        self.reference = nil
        lock.unlock()
        if let reference { AuthorizationFree(reference, [.destroyRights]) }
    }

    deinit { finish() }
}

public enum UninstallHelperAuthorization {
    public static let externalFormLength = MemoryLayout<AuthorizationExternalForm>.size
    private static let administratorRule = "authenticate-admin-nonshared"
    private static let log = Logger(subsystem: "com.macdefier.app", category: "uninstall-helper-authorization")
    static let clientAuthorizationFlags: AuthorizationFlags = [.interactionAllowed, .extendRights]
    static let helperAuthorizationFlags: AuthorizationFlags = [.extendRights]

    /// Production daemon startup only. The client never edits the authorization
    /// database. Do not accept or replace a preexisting unexpected policy.
    public static func ensureRightDefinition(endpoint: UninstallHelperEndpoint) throws {
        guard geteuid() == 0 else { throw UninstallHelperFailure("uninstall_helper_root_required") }
        try requireAdministratorRule()
        if let definition = try existingDefinition(endpoint.authorizationRightName) {
            guard isExpectedDefinition(definition) else { throw invalidPolicy() }
            return
        }
        var authorization: AuthorizationRef?
        try check(AuthorizationCreate(nil, nil, [], &authorization), stage: "define-create")
        guard let authorization else { throw UninstallHelperFailure("uninstall_helper_authorization_invalid") }
        defer { AuthorizationFree(authorization, []) }
        try endpoint.authorizationRightName.withCString { name in
            try check(AuthorizationRightSet(authorization, name, administratorRule as CFString,
                                            "Authorize moving the selected app to Trash." as CFString, nil, nil), stage: "define-right")
        }
        try requireExpectedDefinition(endpoint.authorizationRightName)
    }

    /// Call off the main thread, after a signature-checked hello has completed.
    /// A fresh handle is required for each move; finish after the reply or failure.
    public static func requestExternalForm(endpoint: UninstallHelperEndpoint) throws -> UninstallAuthorizationHandle {
        try requireExpectedDefinition(endpoint.authorizationRightName)
        var authorization: AuthorizationRef?
        try check(AuthorizationCreate(nil, nil, [], &authorization), stage: "client-create")
        guard let authorization else { throw UninstallHelperFailure("uninstall_helper_authorization_invalid") }
        do {
            // PreAuthorize may return success without credentials for a
            // zero-timeout rule. Obtain real, nonshared authorization here,
            // before sending a move; the helper must never need to display UI.
            try copyRights(authorization, rightName: endpoint.authorizationRightName,
                           flags: clientAuthorizationFlags, stage: "client-authorize")
            var form = AuthorizationExternalForm()
            try check(AuthorizationMakeExternalForm(authorization, &form), stage: "client-export")
            let data = withUnsafeBytes(of: &form) { Data($0) }
            return UninstallAuthorizationHandle(reference: authorization, externalForm: data)
        } catch {
            AuthorizationFree(authorization, [.destroyRights])
            throw error
        }
    }

    /// Must run in the helper immediately before the bounded move. No UI is
    /// allowed here and neither a client boolean nor preauthorization is trusted.
    public static func verifyExternalForm(_ data: Data, endpoint: UninstallHelperEndpoint) throws {
        guard data.count == externalFormLength else {
            throw UninstallHelperFailure("uninstall_helper_authorization_invalid")
        }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
        try requireExpectedDefinition(endpoint.authorizationRightName)
        var authorization: AuthorizationRef?
        try check(AuthorizationCreateFromExternalForm(&form, &authorization), stage: "helper-import")
        guard let authorization else { throw UninstallHelperFailure("uninstall_helper_authorization_invalid") }
        defer { AuthorizationFree(authorization, []) }
        try copyRights(authorization, rightName: endpoint.authorizationRightName,
                       flags: helperAuthorizationFlags, stage: "helper-verify")
    }

    private static func copyRights(_ authorization: AuthorizationRef, rightName: String,
                                   flags: AuthorizationFlags, stage: String) throws {
        try rightName.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            try withUnsafeMutablePointer(to: &item) { item in
                var rights = AuthorizationRights(count: 1, items: item)
                try check(AuthorizationCopyRights(authorization, &rights, nil, flags, nil), stage: stage)
            }
        }
    }

    static func isExpectedDefinition(_ definition: [String: Any]) -> Bool {
        guard definition["class"] as? String == "rule", definition["mechanisms"] == nil else { return false }
        let rules: [String]
        if let value = definition["rule"] as? [String] { rules = value }
        else if let value = definition["rule"] as? String { rules = [value] }
        else { return false }
        guard rules == [administratorRule] else { return false }
        if let count = definition["k-of-n"] {
            guard let count = count as? NSNumber, count.intValue == 1 else { return false }
        }
        return true
    }

    static func isExpectedAdministratorRule(_ definition: [String: Any]) -> Bool {
        let allowedKeys: Set<String> = ["class", "group", "timeout", "shared", "allow-root",
            "authenticate-user", "session-owner", "tries", "comment", "created", "modified",
            "version", "identifier", "requirement", "default-prompt"]
        guard Set(definition.keys).isSubset(of: allowedKeys),
              definition["class"] as? String == "user", definition["group"] as? String == "admin",
              integer(definition["timeout"]) == 30,
              boolean(definition["shared"]) == false, boolean(definition["allow-root"]) == false,
              boolean(definition["session-owner"]) == false, boolean(definition["authenticate-user"]) == true,
              let tries = integer(definition["tries"]), tries > 0 else { return false }
        return true
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return nil }
        return Int(exactly: number.int64Value)
    }

    private static func requireAdministratorRule() throws {
        guard let rule = try existingDefinition(administratorRule), isExpectedAdministratorRule(rule) else { throw invalidPolicy() }
    }

    private static func existingDefinition(_ rightName: String) throws -> [String: Any]? {
        var definition: CFDictionary?
        let status = rightName.withCString { AuthorizationRightGet($0, &definition) }
        if status == errAuthorizationDenied { return nil }
        guard status == errAuthorizationSuccess, let definition = definition as? [String: Any] else {
            throw invalidPolicy()
        }
        return definition
    }

    private static func requireExpectedDefinition(_ rightName: String) throws {
        try requireAdministratorRule()
        guard let definition = try existingDefinition(rightName), isExpectedDefinition(definition) else {
            throw invalidPolicy()
        }
    }

    private static func invalidPolicy() -> UninstallHelperFailure {
        UninstallHelperFailure("uninstall_helper_authorization_policy_invalid")
    }

    private static func check(_ status: OSStatus, stage: String) throws {
        guard status != errAuthorizationSuccess else { return }
        log.error("authorization failed stage=\(stage, privacy: .public) status=\(status, privacy: .public)")
        if status == errAuthorizationCanceled { throw UninstallHelperFailure("uninstall_authorization_cancelled") }
        if status == errAuthorizationInteractionNotAllowed { throw UninstallHelperFailure("uninstall_helper_authorization_expired") }
        if status == errAuthorizationInvalidRef || status == errAuthorizationInvalidSet
            || status == errAuthorizationInvalidPointer || status == errAuthorizationInternal {
            throw UninstallHelperFailure("uninstall_helper_authorization_invalid")
        }
        throw UninstallHelperFailure("uninstall_helper_authorization_denied")
    }
}
