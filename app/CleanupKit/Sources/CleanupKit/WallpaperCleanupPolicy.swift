// WallpaperCleanupPolicy — narrow, fail-closed cleanup for macOS Aerial assets.
// Only individual unused resources are eligible. The active wallpaper state is
// re-read by the trash gate, so a selection cannot become unsafe after a rescan.

import Foundation

enum WallpaperCleanupPolicy {
    private static let provider = "com.apple.wallpaper.choice.aerials"
    private static let shuffleAllID = "shuffle-all-aerials"

    private struct Asset {
        let id: String
        let label: String
    }

    private struct ProtectionState {
        let protectedAssetIDs: Set<String>
        let protectsAllManifestAssets: Bool
    }

    private static func aerialRoot(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
    }

    private static func indexPath(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// Only direct .mov/.png children of the two Aerial resource folders.
    static func isManagedResourcePath(_ path: String, home: String) -> Bool {
        let candidate = PathGate.standardizeOnly(path)
        let root = PathGate.standardizeOnly(aerialRoot(home: home))
        let parents = [(root + "/videos", "mov"), (root + "/thumbnails", "png")]
        for (parent, ext) in parents where candidate.hasPrefix(parent + "/") {
            let relative = String(candidate.dropFirst(parent.count + 1))
            return !relative.isEmpty && !relative.contains("/")
                && URL(fileURLWithPath: relative).pathExtension.lowercased() == ext
        }
        return false
    }

    /// Fail closed when the system state cannot be read. This is also called by
    /// PathGate at confirmation/execution time, not just during preview.
    static func isSafeToTrash(_ path: String, home: String) -> Bool {
        guard isManagedResourcePath(path, home: home),
              PathGate.normalize(path) == PathGate.standardizeOnly(path),
              FileManager.default.fileExists(atPath: path),
              let state = protectionState(home: home)
        else { return false }

        if state.protectsAllManifestAssets { return false }
        let assetID = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return !state.protectedAssetIDs.contains(assetID)
    }

    /// One preview row per resource; matching video and thumbnail are a single
    /// reversible action so macOS does not retain a stale preview tile.
    static func scan(home: String) -> [CleanableItem] {
        let root = aerialRoot(home: home)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let state = protectionState(home: home),
              let assets = manifestAssets(home: home),
              !state.protectsAllManifestAssets
        else { return [] }

        let labels = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.label) })
        let videosRoot = root + "/videos"
        let thumbsRoot = root + "/thumbnails"
        var rows: [String: (primary: String, extras: [String], bytes: UInt64)] = [:]

        func add(_ path: String) {
            guard fm.fileExists(atPath: path), isSafeToTrash(path, home: home) else { return }
            let bytes = fileSize(path)
            guard bytes > 0 else { return }
            let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if var row = rows[id] {
                row.extras.append(path)
                row.bytes &+= bytes
                rows[id] = row
            } else {
                rows[id] = (path, [], bytes)
            }
        }

        for (directory, ext) in [(videosRoot, "mov"), (thumbsRoot, "png")] {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where name.lowercased().hasSuffix("." + ext) {
                add(directory + "/" + name)
            }
        }

        return rows.values.map { row in
            let id = URL(fileURLWithPath: row.primary).deletingPathExtension().lastPathComponent
            let label = labels[id] ?? id
            return CleanableItem(
                name: label,
                path: row.primary,
                bytes: row.bytes,
                category: .wallpaper,
                isSelected: false,
                appName: "macOS",
                displayTitle: "macOS 动态壁纸 · \(label)",
                whatIsIt: "未在当前壁纸或轮播设置中使用的 Aerial 视频/缩略图",
                ifCleaned: "当前正在使用的壁纸不会列入；macOS 以后需要时可重新下载",
                risk: .rebuild,
                extraPaths: row.extras
            )
        }.sorted { $0.bytes > $1.bytes }
    }

    private static func protectionState(home: String) -> ProtectionState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath(home: home))),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }

        let choices = aerialChoices(in: plist)
        guard !choices.contains(where: { $0 == nil }) else { return nil }

        var protected = Set<String>()
        var protectsAll = false
        for choice in choices {
            guard let id = choice else { continue }
            if id == shuffleAllID || id.lowercased().contains("shuffle") {
                protectsAll = true
            } else {
                protected.insert(id)
            }
        }
        return ProtectionState(protectedAssetIDs: protected, protectsAllManifestAssets: protectsAll)
    }

    private static func aerialChoices(in value: Any) -> [String?] {
        var ids: [String?] = []

        func walk(_ raw: Any) {
            if let data = raw as? Data,
               let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                walk(decoded)
                return
            }
            if let dict = raw as? NSDictionary {
                if dict["Provider"] as? String == provider {
                    var assetID: String?
                    if let config = dict["Configuration"],
                       let decoded = decode(config) as? NSDictionary {
                        assetID = decoded["assetID"] as? String
                    }
                    ids.append(assetID)
                }
                for item in dict.allValues { walk(item) }
            } else if let array = raw as? NSArray {
                for item in array { walk(item) }
            }
        }

        walk(value)
        return ids
    }

    private static func decode(_ value: Any) -> Any {
        guard let data = value as? Data,
              let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return value }
        return decoded
    }

    private static func manifestAssets(home: String) -> [Asset]? {
        let path = aerialRoot(home: home) + "/manifest/entries.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAssets = object["assets"] as? [[String: Any]]
        else { return nil }

        return rawAssets.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            return Asset(id: id, label: (raw["accessibilityLabel"] as? String) ?? id)
        }
    }

    private static func fileSize(_ path: String) -> UInt64 {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }
}
