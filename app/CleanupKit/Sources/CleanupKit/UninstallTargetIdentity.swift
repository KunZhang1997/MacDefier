// UninstallTargetIdentity — preflight snapshot retained after the .app is moved.

import Foundation

public struct UninstallTargetIdentity: Sendable, Hashable {
    public let bundleID: String
    public let displayName: String
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let originalAppPath: String
    public let appGroups: [String]
    public let verifiedResidualPaths: Set<String>

    public init(app: InstalledApp, residualPaths: [String]) {
        self.bundleID = app.bundleIdentifier
        self.displayName = app.name
        self.signingIdentifier = nil
        self.teamIdentifier = nil
        self.originalAppPath = app.path
        self.appGroups = residualPaths.filter { $0.contains("/Library/Group Containers/") }
        self.verifiedResidualPaths = Set(residualPaths.map(PathGate.normalize))
    }

    public init(bundleID: String, displayName: String, originalAppPath: String, verifiedResidualPaths: [String] = []) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.signingIdentifier = nil
        self.teamIdentifier = nil
        self.originalAppPath = originalAppPath
        self.appGroups = []
        self.verifiedResidualPaths = Set(verifiedResidualPaths.map(PathGate.normalize))
    }
}
