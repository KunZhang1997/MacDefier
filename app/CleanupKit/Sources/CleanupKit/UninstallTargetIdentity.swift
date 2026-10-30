// UninstallTargetIdentity — preflight snapshot retained after the .app is moved.

import Foundation
import Darwin
import Security

public struct UninstallTargetIdentity: Sendable, Hashable {
    public let bundleID: String
    public let displayName: String
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let originalAppPath: String
    public let appGroups: [String]
    public let verifiedResidualPaths: Set<String>
    private let embeddedExtensions: [EmbeddedExtension]
    private let mainBundleSnapshot: UninstallFileBoundary.Snapshot?

    struct Signature: Hashable, Sendable {
        let identifier: String
        let teamIdentifier: String
    }

    private struct EmbeddedExtension: Hashable, Sendable {
        let path: String
        let signature: Signature
    }

    var hasVerifiedExtensions: Bool { !embeddedExtensions.isEmpty }

    public init(app: InstalledApp, residualPaths: [String]) {
        self.init(app: app, residualPaths: residualPaths, signatureReader: Self.validSignature)
    }

    // Isolated fixtures inject signatures; production always verifies sealed code.
    init(app: InstalledApp, residualPaths: [String], signatureReader: (String) -> Signature?) {
        self.bundleID = app.bundleIdentifier
        self.displayName = app.name
        self.originalAppPath = app.path
        self.appGroups = residualPaths.filter { $0.contains("/Library/Group Containers/") }
        self.verifiedResidualPaths = Set(residualPaths.map(PathGate.normalize))
        let snapshot = try? UninstallFileBoundary.snapshot(app.path)
        self.mainBundleSnapshot = snapshot
        // Only container cleanup needs embedded-code evidence. Plain app uninstall
        // stays available for unsigned apps and does not incur a signature walk.
        guard residualPaths.contains(where: { $0.contains("/Library/Containers/") }),
              let snapshot, snapshot.item.kind == mode_t(S_IFDIR),
              let signature = signatureReader(app.path), signature.identifier == app.bundleIdentifier,
              !signature.teamIdentifier.isEmpty,
              (try? UninstallFileBoundary.validate(snapshot)) != nil else {
            self.signingIdentifier = nil
            self.teamIdentifier = nil
            self.embeddedExtensions = []
            return
        }
        self.signingIdentifier = signature.identifier
        self.teamIdentifier = signature.teamIdentifier
        let plugins = URL(fileURLWithPath: app.path).appendingPathComponent("Contents/PlugIns")
        let children = (try? FileManager.default.contentsOfDirectory(at: plugins,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var verified: [EmbeddedExtension] = []
        for url in children.prefix(128) where url.pathExtension == "appex" {
            guard !Task.isCancelled,
                  let child = try? UninstallFileBoundary.snapshot(url.path),
                  child.item.kind == mode_t(S_IFDIR),
                  PathGate.normalize(url.path) == PathGate.standardizeOnly(url.path),
                  let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let identifier = info["CFBundleIdentifier"] as? String,
                  let extensionInfo = info["NSExtension"] as? [String: Any],
                  extensionInfo["NSExtensionPointIdentifier"] is String,
                  let childSignature = signatureReader(url.path), childSignature.identifier == identifier,
                  childSignature.teamIdentifier == signature.teamIdentifier,
                  (try? UninstallFileBoundary.validate(child)) != nil else { continue }
            verified.append(EmbeddedExtension(path: PathGate.standardizeOnly(url.path), signature: childSignature))
        }
        // The parent seal must still cover the same embedded code after discovery.
        self.embeddedExtensions = !Task.isCancelled
            && (try? UninstallFileBoundary.validate(snapshot)) != nil
            && signatureReader(app.path) == signature ? verified : []
    }

    public init(bundleID: String, displayName: String, originalAppPath: String, verifiedResidualPaths: [String] = []) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.signingIdentifier = nil
        self.teamIdentifier = nil
        self.originalAppPath = originalAppPath
        self.appGroups = []
        self.verifiedResidualPaths = Set(verifiedResidualPaths.map(PathGate.normalize))
        self.embeddedExtensions = []
        self.mainBundleSnapshot = nil
    }

    func mainBundleMatchesSnapshot(_ snapshot: UninstallFileBoundary.Snapshot) -> Bool {
        mainBundleSnapshot == snapshot
    }

    /// The same ownership policy is used for the preview and the final gate.
    /// Only the selected main app may still exist in the preview; execution never
    /// ignores a live owner. An extension needs exact sealed-path evidence.
    func containerRetentionReason(_ ownership: ContainerOwnership, preview: Bool = false) -> String? {
        let path = PathGate.normalize(ownership.path)
        if path.contains("/Library/Group Containers/") { return "container_shared" }
        guard verifiedResidualPaths.contains(path), path == PathGate.standardizeOnly(ownership.path),
              let containerPart = path.range(of: "/Library/Containers/", options: .backwards),
              !path[containerPart.upperBound...].isEmpty,
              !path[containerPart.upperBound...].contains("/") else { return "container_unverified" }
        guard ownership.confidence == .verifiedOrphan || ownership.confidence == .installedOwner,
              let ownerID = ownership.bundleID else { return "container_unverified" }

        if ownerID.caseInsensitiveCompare(bundleID) != .orderedSame {
            guard let owned = embeddedExtensions.first(where: {
                $0.signature.identifier.caseInsensitiveCompare(ownerID) == .orderedSame
            }) else { return "extension_unverified" }
            guard !ownership.applicationBundlePaths.isEmpty,
                  ownership.applicationBundlePaths.allSatisfy({
                      PathGate.standardizeOnly($0) == owned.path && PathGate.normalize($0) == owned.path
                  }),
                  ownership.signingIdentifier.map({ $0.caseInsensitiveCompare(ownerID) == .orderedSame }) ?? true,
                  ownership.teamIdentifiers.allSatisfy({ $0 == owned.signature.teamIdentifier })
            else { return "container_changed" }
        } else if let teamIdentifier,
                  !ownership.teamIdentifiers.allSatisfy({ $0 == teamIdentifier }) {
            return "container_changed"
        }

        if ownership.confidence == .installedOwner {
            guard ownership.hasVerifiableApplicationPaths else { return "container_unverified" }
            guard preview, !ownership.liveOwnerPaths.isEmpty,
                  ownership.liveOwnerPaths.allSatisfy({
                      PathGate.normalize($0) == PathGate.normalize(originalAppPath)
                  }) else { return "container_in_use" }
        }
        return nil
    }

    private static func validSignature(_ path: String) -> Signature? {
        guard !Task.isCancelled else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { return nil }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !identifier.isEmpty, !team.isEmpty else { return nil }
        return Signature(identifier: identifier, teamIdentifier: team)
    }
}
