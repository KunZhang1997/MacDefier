// ContainerOwnership — metadata-first ownership evidence for sandbox containers.
// A container may be visible without being deletable; callers must keep that distinction.

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(AppKit)
import AppKit
#endif

public enum ContainerOwnershipConfidence: String, Sendable, Hashable {
    case verifiedOrphan
    case installedOwner
    case ambiguous
    case protected
    case unreadable
}

public struct ContainerOwnership: Sendable, Hashable {
    public let path: String
    public let bundleID: String?
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let applicationBundlePath: String?
    public let confidence: ContainerOwnershipConfidence
    public let evidence: [String]

    public init(path: String, bundleID: String?, signingIdentifier: String? = nil, teamIdentifier: String? = nil, applicationBundlePath: String? = nil, confidence: ContainerOwnershipConfidence, evidence: [String]) {
        self.path = path
        self.bundleID = bundleID
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.applicationBundlePath = applicationBundlePath
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// Direct-child container inventory.  It deliberately does not make Containers part
/// of the generic junk scan: visibility and a deletion grant are separate things.
public enum ContainerOwnershipScanner {
    private static let fm = FileManager.default

    public static func scan(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        installed: [InstalledApp],
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> [ContainerOwnership] {
        let roots = [
            (home + "/Library/Containers", false),
            (home + "/Library/Group Containers", true)
        ]
        var out: [ContainerOwnership] = []
        for (root, isGroup) in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names {
                if isCancelled() { return out }
                let path = (root as NSString).appendingPathComponent(name)
                guard isDirectDirectory(path) else { continue }
                out.append(inspect(path: path, isGroupContainer: isGroup, installed: installed))
            }
        }
        return out
    }

    public static func inspect(
        path: String,
        isGroupContainer: Bool,
        installed: [InstalledApp]
    ) -> ContainerOwnership {
        let normalized = PathGate.normalize(path)
        let name = URL(fileURLWithPath: normalized).lastPathComponent
        guard normalized == PathGate.standardizeOnly(path), !isSymlink(path) else {
            return ContainerOwnership(path: path, bundleID: nil, confidence: .ambiguous,
                                      evidence: ["路径是符号链接或解析后越界"])
        }

        let metadata = metadataDictionary(at: normalized)
        let metaIDs = stringValues(named: "MCMMetadataIdentifier", in: metadata)
        let metaID = metaIDs.first
        let xattrID = xattrString(path: normalized, name: "com.apple.containermanager.identifier")
        let signingIDs = stringValues(named: "signingIdentifier", in: metadata)
        let signingID = signingIDs.first
        let teamID = stringValue(named: "teamIdentifier", in: metadata)
        let appPaths = stringValues(named: "application_bundle", in: metadata)
        let appPath = appPaths.first
        let nameID = AppOwnership.looksLikeReverseDNS(name) ? name : nil
        let ids = (metaIDs + signingIDs + [xattrID, nameID].compactMap { $0 }).map { $0.lowercased() }
        let uniqueIDs = Set(ids)
        let evidence = [
            metaID.map { "MCMMetadataIdentifier=\($0)" },
            xattrID.map { "container xattr=\($0)" },
            signingID.map { "signingIdentifier=\($0)" },
            teamID.map { "teamIdentifier=\($0)" },
            appPath.map { "original application_bundle=\($0)" },
            nameID.map { "directory bundle ID=\($0)" }
        ].compactMap { $0 }

        guard !name.hasPrefix("com.apple."),
              !ids.contains(where: { $0.hasPrefix("com.apple.") }),
              !ids.contains("com.macdefier.app")
        else {
            return ContainerOwnership(path: normalized, bundleID: metaID ?? xattrID ?? signingID,
                                      signingIdentifier: signingID, teamIdentifier: teamID,
                                      applicationBundlePath: appPath, confidence: .protected,
                                      evidence: evidence + ["系统或 MacDefier 容器"])
        }
        guard uniqueIDs.count == 1, let bundleID = uniqueIDs.first, AppOwnership.looksLikeReverseDNS(bundleID) else {
            return ContainerOwnership(path: normalized, bundleID: metaID ?? xattrID ?? signingID,
                                      signingIdentifier: signingID, teamIdentifier: teamID,
                                      applicationBundlePath: appPath, confidence: .ambiguous,
                                      evidence: evidence.isEmpty ? ["缺少可验证的归属 metadata"] : evidence + ["归属 metadata 冲突"])
        }
        if isGroupContainer {
            // Groups can be shared.  Until every consumer is proven absent, listing is
            // useful but deletion is never offered.
            return ContainerOwnership(path: normalized, bundleID: bundleID,
                                      signingIdentifier: signingID, teamIdentifier: teamID,
                                      applicationBundlePath: appPath, confidence: .ambiguous,
                                      evidence: evidence + ["Group Container 可能被多个 App 共享"])
        }
        let originalApps = appPaths.compactMap(rootApplicationPath)
        if hasLiveApp(bundleID: bundleID, installed: installed)
            || originalApps.contains(where: { applicationPathState($0) == .present })
            || installed.contains(where: { app in
                originalApps.contains { original in
                    // A renamed/localized app or a duplicate name is enough to protect
                    // data. This does not grant ownership to the uninstall matcher.
                    let oldName = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent.mdNormalizedForMatching()
                    return !oldName.isEmpty && (oldName == app.name.mdNormalizedForMatching()
                        || oldName == URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.mdNormalizedForMatching())
                }
            }) {
            return ContainerOwnership(path: normalized, bundleID: bundleID,
                                      signingIdentifier: signingID, teamIdentifier: teamID,
                                      applicationBundlePath: appPath, confidence: .installedOwner,
                                      evidence: evidence + ["归属应用或其主程序仍存在"])
        }
        guard metaID?.lowercased() == bundleID || xattrID?.lowercased() == bundleID || signingID?.lowercased() == bundleID else {
            return ContainerOwnership(path: normalized, bundleID: bundleID,
                                      signingIdentifier: signingID, teamIdentifier: teamID,
                                      applicationBundlePath: appPath, confidence: .ambiguous,
                                      evidence: evidence + ["仅目录名推断，不能删除"])
        }
        // A missing inventory match is not evidence of uninstall. Require a recorded,
        // local application location that is conclusively absent; unreadable paths,
        // detached volumes, temporary builds and metadata without an owner stay unknown.
        guard !appPaths.isEmpty, originalApps.count == appPaths.count,
              originalApps.allSatisfy({ isStableInstallationPath($0) && applicationPathState($0) == .missing }) else {
            return ContainerOwnership(path: normalized, bundleID: bundleID,
                                      signingIdentifier: signingID, teamIdentifier: teamID,
                                      applicationBundlePath: appPath, confidence: .ambiguous,
                                      evidence: evidence + ["缺少可核验的原应用位置，不能判为卸载残留"])
        }
        return ContainerOwnership(path: normalized, bundleID: bundleID,
                                  signingIdentifier: signingID, teamIdentifier: teamID,
                                  applicationBundlePath: appPath, confidence: .verifiedOrphan,
                                  evidence: evidence + ["原应用位置已不存在，未找到已安装的归属应用"])
    }

    private static func hasLiveApp(bundleID: String, installed: [InstalledApp]) -> Bool {
        if installed.contains(where: { AppOwnership.bundleIDMatches(folderName: bundleID, bundleID: $0.bundleIdentifier) }) {
            return true
        }
        #if canImport(AppKit)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), fm.fileExists(atPath: url.path) {
            return true
        }
        #endif
        return false
    }

    /// Use the outer app, not an embedded helper that an update may have replaced.
    private static func rootApplicationPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        var components: [String] = []
        for part in path.split(separator: "/") {
            components.append(String(part))
            if part.lowercased().hasSuffix(".app") { return "/" + components.joined(separator: "/") }
        }
        return nil
    }

    private enum ApplicationPathState { case present, missing, unknown }

    private static func applicationPathState(_ path: String) -> ApplicationPathState {
        #if canImport(Darwin)
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        return errno == ENOENT ? .missing : .unknown
        #else
        return fm.fileExists(atPath: path) ? .present : .unknown
        #endif
    }

    private static func isStableInstallationPath(_ path: String) -> Bool {
        let roots = ["/Applications", fm.homeDirectoryForCurrentUser.path + "/Applications", "/Users/Shared"]
        // Symlinked installation roots might point at a disconnected volume.
        return roots.contains { path.hasPrefix($0 + "/") }
            && PathGate.normalize(path) == PathGate.standardizeOnly(path)
    }

    private static func stringValues(named key: String, in value: Any) -> [String] {
        var result: [String] = []
        if let dict = value as? NSDictionary {
            for (rawKey, rawValue) in dict {
                if String(describing: rawKey).caseInsensitiveCompare(key) == .orderedSame,
                   let string = rawValue as? String, !string.isEmpty { result.append(string) }
                result.append(contentsOf: stringValues(named: key, in: rawValue))
            }
        } else if let array = value as? [Any] {
            for member in array { result.append(contentsOf: stringValues(named: key, in: member)) }
        }
        return Array(Set(result)).sorted()
    }

    private static func metadataDictionary(at path: String) -> NSDictionary {
        let file = (path as NSString).appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        return NSDictionary(contentsOfFile: file) ?? [:]
    }

    private static func stringValue(named key: String, in value: Any) -> String? {
        if let dict = value as? NSDictionary {
            for (rawKey, rawValue) in dict {
                if String(describing: rawKey).caseInsensitiveCompare(key) == .orderedSame,
                   let string = rawValue as? String, !string.isEmpty { return string }
                if let found = stringValue(named: key, in: rawValue) { return found }
            }
        } else if let array = value as? [Any] {
            for member in array {
                if let found = stringValue(named: key, in: member) { return found }
            }
        }
        return nil
    }

    private static func isDirectDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func xattrString(path: String, name: String) -> String? {
        #if canImport(Darwin)
        let count = getxattr(path, name, nil, 0, 0, 0)
        guard count > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let capacity = bytes.count
        let read = bytes.withUnsafeMutableBytes { ptr in
            getxattr(path, name, ptr.baseAddress, capacity, 0, 0)
        }
        guard read > 0 else { return nil }
        return String(bytes: bytes.prefix(read), encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        #else
        return nil
        #endif
    }
}
