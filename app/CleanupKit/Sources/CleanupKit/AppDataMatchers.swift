// AppDataMatchers — size, list children, dedupe helpers for inventory.

import Foundation

enum AppDataMatchers {
    private static let fm = FileManager.default

    static func normalize(_ path: String) -> String {
        AppDataLocations.normalize(path)
    }

    static func directorySize(
        at path: String,
        fileCap: Int = 300_000,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> UInt64 {
        guard !isCancelled() else { return 0 }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let vals = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
            ])
            return UInt64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? vals?.fileSize ?? 0)
        }
        var total: UInt64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ],
            options: [] // include hidden + package guts for game / support data
        ) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            if isCancelled() { break }
            count += 1
            if count > fileCap { break }
            guard let vals = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ]),
                  vals.isRegularFile == true
            else { continue }
            let size = vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? vals.fileSize ?? 0
            total &+= UInt64(size)
        }
        return total
    }

    static func listImmediateChildren(of root: String) -> [String] {
        guard fm.fileExists(atPath: root),
              let names = try? fm.contentsOfDirectory(atPath: root)
        else { return [] }
        return names.filter { !$0.hasPrefix(".") }.map {
            (root as NSString).appendingPathComponent($0)
        }
    }

    static func makeItem(
        name: String,
        path: String,
        selected: Bool,
        minimumBytes: UInt64,
        appName: String?,
        parentPath: String?,
        displayTitle: String? = nil
    ) -> CleanableItem? {
        guard fm.fileExists(atPath: path) else { return nil }
        guard AppDataLocations.isUnderAllowedRoot(path) else { return nil }
        let size = directorySize(at: path)
        if size < minimumBytes { return nil }
        return CleanableItem(
            name: name,
            path: path,
            bytes: size,
            category: .largeAppData,
            isSelected: selected,
            appName: appName,
            displayTitle: displayTitle,
            parentPath: parentPath
        )
    }

    static func dedupe(_ items: [CleanableItem]) -> [CleanableItem] {
        var seen = Set<String>()
        var out: [CleanableItem] = []
        for item in items.sorted(by: { $0.bytes > $1.bytes }) {
            let key = normalize(item.path)
            // Prefer more specific child over parent when both present
            if seen.contains(where: { $0.hasPrefix(key + "/") }) {
                continue
            }
            if let parent = seen.first(where: { key.hasPrefix($0 + "/") }) {
                // child of already-listed path: keep both if different; only skip exact dups
                _ = parent
            }
            if seen.insert(key).inserted {
                out.append(item)
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Drop parent if any selected child path is under it (for display list, keep children).
    static func preferChildrenOverParents(_ items: [CleanableItem]) -> [CleanableItem] {
        let paths = Set(items.map { normalize($0.path) })
        return items.filter { item in
            let p = normalize(item.path)
            let hasChild = paths.contains { other in
                other != p && other.hasPrefix(p + "/")
            }
            return !hasChild
        }.sorted { $0.bytes > $1.bytes }
    }
}
