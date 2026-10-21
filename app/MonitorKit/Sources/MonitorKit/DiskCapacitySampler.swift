// Disk capacity sampling — volumes with role labels (system / external / disk image…).
// Pattern adapted from Stats Modules/Disk CapacityReader (MIT); DA for identity.

import DiskArbitration
import Foundation

public final class DiskCapacitySampler: Sampler<[DiskVolume]> {
    public override func read() {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsLocalKey,
            .volumeIsRootFileSystemKey,
            .volumeIsAutomountedKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else {
            publish([])
            return
        }

        let session = DASessionCreate(kCFAllocatorDefault)
        var volumes: [DiskVolume] = []
        var seenPaths = Set<String>()

        for url in urls {
            let components = url.pathComponents
            let isRoot = components.count == 1 || url.path == "/"
            let isVolume = components.count > 1 && components[1] == "Volumes"
            guard isRoot || isVolume else { continue }

            let path = url.path
            guard seenPaths.insert(path).inserted else { continue }

            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let total = Double(values.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }

            let freeImportant = values.volumeAvailableCapacityForImportantUsage.map { Double($0) }
            let freeBasic = values.volumeAvailableCapacity.map { Double($0) }
            guard let free = Self.validFreeCapacity(total: total, important: freeImportant, basic: freeBasic) else { continue }
            let name = values.volumeName ?? (isRoot ? "Macintosh HD" : url.lastPathComponent)

            let identity = classify(url: url, values: values, session: session)

            volumes.append(DiskVolume(
                name: name,
                path: path,
                bsdName: identity.bsd,
                total: total,
                free: free,
                removable: identity.removable,
                kind: identity.kind,
                protocolName: identity.protocolName
            ))
        }

        // System → internal → external → other → images → network; then by usage
        volumes.sort {
            if $0.kind.sortRank != $1.kind.sortRank {
                return $0.kind.sortRank < $1.kind.sortRank
            }
            return $0.usage > $1.usage
        }
        publish(volumes)
    }

    static func validFreeCapacity(total: Double, important: Double?, basic: Double?) -> Double? {
        guard total.isFinite, total > 0 else { return nil }
        // A missing capacity is not a full disk. Fall back only to a measured, valid value.
        return [important, basic].compactMap { $0 }.first { $0.isFinite && (0...total).contains($0) }
    }

    private struct Identity {
        var kind: DiskVolumeKind
        var bsd: String
        var removable: Bool
        var protocolName: String
    }

    private func classify(
        url: URL,
        values: URLResourceValues,
        session: DASession?
    ) -> Identity {
        var bsd = ""
        var protocolName = ""
        var daInternal: Bool?
        var daRemovable: Bool?
        var daNetwork = false
        var daEjectable = false

        if let session,
           let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
           let desc = DADiskCopyDescription(disk) as NSDictionary? {
            if let name = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String {
                bsd = name
            } else if let cName = DADiskGetBSDName(disk) {
                bsd = String(cString: cName)
            }
            protocolName = (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
            daInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool
            daRemovable = desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool
            daNetwork = (desc[kDADiskDescriptionVolumeNetworkKey as String] as? Bool) == true
            daEjectable = (desc[kDADiskDescriptionMediaEjectableKey as String] as? Bool) == true

            // Media path often ends with .dmg for mounted installers
            if let mediaPath = desc[kDADiskDescriptionDeviceModelKey as String] as? String,
               mediaPath.localizedCaseInsensitiveContains("Disk Image") {
                protocolName = protocolName.isEmpty ? "Disk Image" : protocolName
            }
            if let bus = desc["DADeviceProtocol" as String] as? String, protocolName.isEmpty {
                protocolName = bus
            }
        }

        let urlRemovable = (values.volumeIsRemovable == true) || (values.volumeIsEjectable == true)
        let removable = daRemovable == true || daEjectable || urlRemovable
        let isRoot = url.path == "/" || values.volumeIsRootFileSystem == true

        let kind: DiskVolumeKind
        let protoLower = protocolName.lowercased()
        if daNetwork || values.volumeIsLocal == false {
            kind = .network
        } else if protoLower.contains("disk image")
                    || protoLower.contains("virtual")
                    || isLikelyDiskImageMount(url: url, protocolName: protocolName) {
            kind = .diskImage
        } else if isRoot {
            kind = .system
        } else if removable && daInternal != true {
            kind = .external
        } else if daInternal == true || (!removable && values.volumeIsLocal != false) {
            kind = isRoot ? .system : .internalVol
        } else if removable {
            kind = .external
        } else {
            kind = .other
        }

        return Identity(kind: kind, bsd: bsd, removable: removable, protocolName: protocolName)
    }

    /// Heuristic: installer DMGs often mount under /Volumes with automount.
    private func isLikelyDiskImageMount(url: URL, protocolName: String) -> Bool {
        if protocolName.localizedCaseInsensitiveContains("Disk Image") { return true }
        let name = url.lastPathComponent.lowercased()
        // Common macOS installer / image volume names — only when not root
        if url.path == "/" { return false }
        let imageHints = ["install ", "installer", ".dmg", "macOS ", "macos download"]
        if imageHints.contains(where: { name.contains($0.lowercased()) }) {
            // Weak signal alone; prefer DA protocol. Keep as hint only if path is under /Volumes
            if url.path.hasPrefix("/Volumes/") {
                // Don't force every /Volumes as image — many externals mount there.
                // Only if name looks like OS installer.
                if name.contains("install") || name.contains("macos") { return true }
            }
        }
        return false
    }
}
