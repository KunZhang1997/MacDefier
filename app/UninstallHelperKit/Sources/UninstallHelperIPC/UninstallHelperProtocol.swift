import Foundation

/// A narrow, data-only interface. No command execution, arbitrary destination,
/// user identity or filesystem-probing RPC is exposed.
@objc public protocol UninstallHelperProtocol {
    func hello(_ challenge: String, reply: @escaping (String, String) -> Void)
    func move(_ requestData: Data, authorizationExternalForm: Data,
              reply: @escaping (Data?, String?) -> Void)
}

public enum UninstallHelperLimits {
    public static let maximumRequestBytes = 16_384
    public static func isValidChallenge(_ value: String) -> Bool {
        (16...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }
}

public struct UninstallHelperFailure: Error, LocalizedError, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var errorDescription: String? { code }
}
