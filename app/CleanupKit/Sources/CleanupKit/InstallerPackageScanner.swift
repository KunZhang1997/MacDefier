// Installer discovery shares the bounded, metadata-only disk accounting engine.
// Keeps installers out of the generic large-file bucket and never auto-selects them.

import Darwin
import Foundation

public struct InstallerPackageScanResult: Sendable {
    public let items: [CleanableItem]
    public let isPartial: Bool
}

public enum InstallerPackageScanner {
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
            let stdRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            var rootInfo = stat()
            guard lstat(stdRoot, &rootInfo) == 0 else {
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
            if rootInfo.st_flags & UInt32(SF_DATALESS) != 0 {
                partial = true
                continue
            }

            let rootStarted = ContinuousClock.now
            var entriesVisited = 0
            var stoppedRoot = false

            func remainingSeconds() -> TimeInterval {
                let d = rootStarted.duration(to: .now).components
                let elapsed = Double(d.seconds) + Double(d.attoseconds) / 1e18
                return budget.maxSeconds - elapsed
            }

            func shouldStopRoot() -> Bool {
                if isCancelled() { return true }
                if remainingSeconds() <= 0 { return true }
                if entriesVisited >= budget.maxEntries { return true }
                return false
            }

            func walkDirectory(_ fd: Int32, path currentPath: String, depth: Int, device: dev_t) {
                guard let directory = fdopendir(fd) else {
                    close(fd)
                    partial = true
                    return
                }
                defer { closedir(directory) }
                let parentFD = dirfd(directory)

                while true {
                    if stoppedRoot || shouldStopRoot() {
                        stoppedRoot = true
                        partial = true
                        break
                    }
                    errno = 0
                    guard let entry = readdir(directory) else {
                        if errno != 0 { partial = true }
                        break
                    }
                    let name = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                            String(cString: $0)
                        }
                    }
                    if name == "." || name == ".." { continue }
                    entriesVisited += 1

                    var info = stat()
                    guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                        partial = true
                        continue
                    }
                    let type = info.st_mode & mode_t(S_IFMT)
                    guard type != mode_t(S_IFLNK) else { continue }
                    if info.st_dev != device {
                        partial = true
                        continue
                    }
                    // Match hidden-file exclusion without reading contents.
                    guard !name.hasPrefix("."), info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                    if info.st_flags & UInt32(SF_DATALESS) != 0 {
                        partial = true
                        continue
                    }

                    let childPath = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
                    let isDirectory = type == mode_t(S_IFDIR)
                    let ext = (name as NSString).pathExtension.lowercased()
                    let installerDirectory = isDirectory && (ext == "pkg" || ext == "mpkg")

                    if supportedExtensions.contains(ext) && (type == mode_t(S_IFREG) || installerDirectory) {
                        let itemBytes: UInt64
                        let itemComplete: Bool
                        if installerDirectory {
                            let remEntries = budget.maxEntries - entriesVisited
                            let remSeconds = remainingSeconds()
                            if depth >= budget.maxDepth || remEntries <= 0 || remSeconds <= 0 || isCancelled() {
                                itemBytes = UInt64(max(0, info.st_blocks)) * 512
                                itemComplete = false
                                partial = true
                            } else {
                                let pkgBudget = DiskScanBudget(
                                    maxEntries: remEntries,
                                    maxDepth: budget.maxDepth - depth - 1,
                                    maxSeconds: remSeconds
                                )
                                let summed = DiskUsageScanner.sumAllocatedBytesCountingEntries(
                                    root: URL(fileURLWithPath: childPath),
                                    budget: pkgBudget,
                                    isCancelled: isCancelled
                                )
                                entriesVisited += summed.entriesVisited
                                itemBytes = summed.allocatedBytes
                                itemComplete = summed.isComplete
                                if !itemComplete { partial = true }
                            }
                        } else {
                            itemBytes = UInt64(max(0, info.st_blocks)) * 512
                            itemComplete = true
                        }

                        let normalizedPath = PathGate.normalize(childPath)
                        if seen.insert(normalizedPath).inserted,
                           PathGate.isSafeInstallerPackageTrashPath(normalizedPath, home: home, sharedRoot: sharedRoot) {
                            items.append(CleanableItem(
                                name: name,
                                path: normalizedPath,
                                bytes: itemBytes,
                                category: .installerPackages,
                                isSelected: false,
                                appName: nil,
                                displayTitle: name,
                                whatIsIt: "macOS \(ext.uppercased()) 安装包（不按体积筛选）",
                                ifCleaned: "移入废纸篓，可恢复；确认不再需要安装或测试后再勾选。",
                                risk: .caution,
                                parentPath: currentPath,
                                sizeIsLowerBound: !itemComplete,
                                isDirectory: isDirectory
                            ))
                        }
                        if installerDirectory { continue }
                    }

                    if isDirectory {
                        // Preserve skipsPackageDescendants: an installer inside an app
                        // or another non-installer package is not an independent target.
                        let childURL = URL(fileURLWithPath: childPath, isDirectory: true)
                        guard let values = try? childURL.resourceValues(forKeys: [.isPackageKey]) else {
                            partial = true
                            continue
                        }
                        guard values.isPackage != true else { continue }
                        if depth >= budget.maxDepth {
                            partial = true
                            continue
                        }
                        let childFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        if childFD < 0 {
                            partial = true
                        } else {
                            var opened = stat()
                            if fstat(childFD, &opened) != 0 || opened.st_dev != info.st_dev || opened.st_ino != info.st_ino {
                                close(childFD)
                                partial = true
                            } else {
                                walkDirectory(childFD, path: childPath, depth: depth + 1, device: device)
                            }
                        }
                    }
                }
            }

            let rootFD = open(stdRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if rootFD < 0 {
                partial = true
            } else {
                var opened = stat()
                if fstat(rootFD, &opened) != 0 || opened.st_dev != rootInfo.st_dev || opened.st_ino != rootInfo.st_ino {
                    close(rootFD)
                    partial = true
                } else {
                    walkDirectory(rootFD, path: stdRoot, depth: 0, device: rootInfo.st_dev)
                }
            }
        }

        return InstallerPackageScanResult(items: items.sorted {
            $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
        }, isPartial: partial)
    }
}
