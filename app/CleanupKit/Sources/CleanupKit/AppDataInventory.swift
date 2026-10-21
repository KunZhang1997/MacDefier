// AppDataInventory — large app-data discovery (separate from JunkScanner cache tables).

import Foundation

public enum AppDataInventory {
    private static let fm = FileManager.default
    private static var home: String { fm.homeDirectoryForCurrentUser.path }

    /// Scan P0 conditions → flat CleanableItem list under `.largeAppData`.
    public static func scan() -> [CleanableItem] {
        var items: [CleanableItem] = []
        for condition in AppDataConditions.p0 {
            items.append(contentsOf: scan(condition: condition))
        }
        // Prefer listing children when they cover the bulk; still keep model files.
        return AppDataMatchers.dedupe(items)
    }

    private static func scan(condition: AppDataCondition) -> [CleanableItem] {
        let root = condition.absoluteRoot(home: home)
        guard fm.fileExists(atPath: root) else { return [] }

        var items: [CleanableItem] = []
        var seen = Set<String>()

        func append(_ item: CleanableItem?) {
            guard let item else { return }
            let key = AppDataMatchers.normalize(item.path)
            if seen.insert(key).inserted {
                items.append(item)
            }
        }

        // Preferred children first
        for child in condition.preferredChildren {
            let path = (root as NSString).appendingPathComponent(child)
            append(AppDataMatchers.makeItem(
                name: child,
                path: path,
                selected: false,
                minimumBytes: condition.minChildBytes,
                appName: condition.sourceApp,
                parentPath: root,
                displayTitle: "\(condition.sourceApp) · \(child)"
            ))
        }

        // Other large immediate children
        for path in AppDataMatchers.listImmediateChildren(of: root) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if condition.preferredChildren.contains(name) { continue }
            append(AppDataMatchers.makeItem(
                name: name,
                path: path,
                selected: false,
                minimumBytes: condition.minChildBytes,
                appName: condition.sourceApp,
                parentPath: root,
                displayTitle: "\(condition.sourceApp) · \(name)"
            ))
        }

        // Model files under root
        if condition.expandModelFiles {
            items.append(contentsOf: scanModelFiles(
                under: root,
                sourceApp: condition.sourceApp,
                extensions: condition.modelExtensions,
                nameHints: condition.modelNameHints,
                minBytes: 200 * 1024 * 1024
            ))
        }

        // Fallback: whole root if nothing smaller matched
        if items.isEmpty {
            append(AppDataMatchers.makeItem(
                name: condition.sourceApp,
                path: root,
                selected: false,
                minimumBytes: condition.minRootBytes,
                appName: condition.sourceApp,
                parentPath: nil,
                displayTitle: condition.sourceApp
            ))
        } else {
            // If children exist but leave large unaccounted root-only files, still OK;
            // avoid also adding root when children already listed (double count in UI).
            let childPaths = items.map { AppDataMatchers.normalize($0.path) }
            let hasDirectChild = childPaths.contains { $0.hasPrefix(AppDataMatchers.normalize(root) + "/") }
            if !hasDirectChild {
                append(AppDataMatchers.makeItem(
                    name: condition.sourceApp,
                    path: root,
                    selected: false,
                    minimumBytes: condition.minRootBytes,
                    appName: condition.sourceApp,
                    parentPath: nil,
                    displayTitle: condition.sourceApp
                ))
            }
        }

        return items
    }

    private static func scanModelFiles(
        under root: String,
        sourceApp: String,
        extensions: Set<String>,
        nameHints: [String],
        minBytes: UInt64
    ) -> [CleanableItem] {
        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var items: [CleanableItem] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            let name = fileURL.lastPathComponent.lowercased()
            let hintOK = nameHints.isEmpty || nameHints.contains { name.contains($0.lowercased()) }
            if ext == "bin" && !hintOK { continue }
            let path = fileURL.path
            guard AppDataLocations.isUnderAllowedRoot(path) else { continue }
            let size = AppDataMatchers.directorySize(at: path)
            guard size >= minBytes else { continue }
            items.append(CleanableItem(
                name: fileURL.lastPathComponent,
                path: path,
                bytes: size,
                category: .largeAppData,
                isSelected: false,
                appName: sourceApp,
                displayTitle: "\(sourceApp) · \(fileURL.lastPathComponent)",
                parentPath: root
            ))
            if items.count >= 32 { break }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }
}
