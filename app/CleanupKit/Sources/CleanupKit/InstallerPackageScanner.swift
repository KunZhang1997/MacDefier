// Installer discovery shares the bounded, metadata-only disk accounting engine.
// Keeps installers out of the generic large-file bucket and never auto-selects them.

import Darwin
import Foundation

public struct InstallerPackageScanResult: Sendable {
    public let items: [CleanableItem]
    public let isPartial: Bool
}

public enum InstallerPackageScanner {
    private static let fm = FileManager.default
    public static let supportedExtensions: Set<String> = ["dmg", "pkg", "mpkg"]

    public static func isInstallerPackagePath(_ path: String) -> Bool {
        supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Compatibility wrapper. Call scanReport when discovery quality is displayed.
    public static func scan(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        sharedRoot: String? = "/Users/Shared",
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> [CleanableItem] {
        scanReport(home: home, sharedRoot: sharedRoot, isCancelled: isCancelled).items
    }

    /// Each existing root receives its own traversal budget. There is no byte
    /// threshold or separate result-count cap; discoveries survive an incomplete walk.
    public static func scanReport(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        sharedRoot: String? = "/Users/Shared",
        budget: DiskScanBudget = DiskScanBudget(maxEntries: 15_000, maxSeconds: 1.5),
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> InstallerPackageScanResult {
        var roots = [home + "/Downloads", home + "/Desktop", home + "/Documents"]
        if let sharedRoot { roots.append(sharedRoot) }

        var seen = Set<String>()
        var items: [CleanableItem] = []
        var partial = false
        for root in roots {
            if isCancelled() { partial = true; break }
            var rootInfo = stat()
            guard lstat(root, &rootInfo) == 0 else {
                // Absent optional locations are normal; inaccessible roots are not.
                if errno != ENOENT && errno != ENOTDIR { partial = true }
                continue
            }
            guard rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                // A symlink root is intentionally not followed; discovery there
                // was skipped rather than proven empty.
                partial = true
                continue
            }
            let snapshot = DiskUsageScanner.scan(root: URL(fileURLWithPath: root),
                budget: budget, isCancelled: isCancelled)
            partial = partial || snapshot.root?.isComplete != true
            var pending = snapshot.root?.children ?? []
            // A stopped walk still owns useful metadata. Finish this bounded
            // snapshot, then cancellation prevents starting another root.
            while let nodePath = pending.popLast() {
                guard let node = snapshot.nodes[nodePath], !node.isSymbolicLink else { continue }
                let url = URL(fileURLWithPath: node.path)
                var info = stat()
                guard lstat(node.path, &info) == 0 else { partial = true; continue }
                let type = info.st_mode & mode_t(S_IFMT)
                guard type != mode_t(S_IFLNK) else { continue }
                // Match the former hidden-file exclusion without reading contents.
                guard !url.lastPathComponent.hasPrefix("."), info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                if info.st_flags & UInt32(SF_DATALESS) != 0 { partial = true; continue }
                // Issues aggregate upward; only the child's own device can
                // identify a mount boundary without discarding its siblings.
                if info.st_dev != rootInfo.st_dev { continue }
                let isDirectory = type == mode_t(S_IFDIR)
                guard isDirectory == node.isDirectory else { partial = true; continue }

                let ext = url.pathExtension.lowercased()
                let installerDirectory = isDirectory && (ext == "pkg" || ext == "mpkg")
                if supportedExtensions.contains(ext) && (type == mode_t(S_IFREG) || installerDirectory) {
                    let path = PathGate.normalize(node.path)
                    if seen.insert(path).inserted,
                       PathGate.isSafeInstallerPackageTrashPath(path, home: home, sharedRoot: sharedRoot) {
                        items.append(CleanableItem(
                            name: url.lastPathComponent,
                            path: path,
                            bytes: node.allocatedBytes,
                            category: .installerPackages,
                            isSelected: false,
                            appName: nil,
                            displayTitle: url.lastPathComponent,
                            whatIsIt: "macOS \(ext.uppercased()) 安装包（不按体积筛选）",
                            ifCleaned: "移入废纸篓，可恢复；确认不再需要安装或测试后再勾选。",
                            risk: .caution,
                            parentPath: url.deletingLastPathComponent().path,
                            sizeIsLowerBound: !node.isComplete
                        ))
                    }
                    // A package directory is one item, even if its path is refused.
                    if installerDirectory { continue }
                }
                if isDirectory {
                    // Preserve skipsPackageDescendants: an installer inside an app
                    // or another non-installer package is not an independent target.
                    guard let values = try? url.resourceValues(forKeys: [.isPackageKey]) else {
                        partial = true
                        continue
                    }
                    if values.isPackage != true { pending.append(contentsOf: node.children) }
                }
            }
        }
        return InstallerPackageScanResult(items: items.sorted {
            $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
        }, isPartial: partial)
    }
}
