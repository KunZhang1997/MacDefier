import Darwin
import Foundation

public enum DiskScanIssue: String, Sendable, Hashable, CaseIterable {
    case unreadable, changed, entryLimit, depthLimit, timeLimit, cancelled, otherVolume, cloudPlaceholder, inProgress
}

/// Allocated bytes are filesystem accounting, not a promise of reclaimable space.
/// Hard links are counted once per scan. APFS clones and snapshots can still share blocks.
public struct DiskUsageNode: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isHardLinkDuplicate: Bool
    public var allocatedBytes: UInt64
    public var logicalBytes: UInt64
    public var hardLinkBytesCountedElsewhere: UInt64
    public var children: [String]
    public var issues: Set<DiskScanIssue>
    public var hasOmittedSmallChildren: Bool
    public var isComplete: Bool { issues.isEmpty }
    public var hasTruncatedWalk: Bool {
        !issues.isDisjoint(with: [.inProgress, .cancelled, .entryLimit, .timeLimit, .depthLimit])
    }
    public var name: String { path == "/" ? "/" : URL(fileURLWithPath: path).lastPathComponent }

    public init(
        path: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isHardLinkDuplicate: Bool,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        hardLinkBytesCountedElsewhere: UInt64,
        children: [String],
        issues: Set<DiskScanIssue>,
        hasOmittedSmallChildren: Bool = false
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isHardLinkDuplicate = isHardLinkDuplicate
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.hardLinkBytesCountedElsewhere = hardLinkBytesCountedElsewhere
        self.children = children
        self.issues = issues
        self.hasOmittedSmallChildren = hasOmittedSmallChildren
    }
}

public struct DiskUsageSnapshot: Sendable {
    public let rootPath: String
    public let nodes: [String: DiskUsageNode]
    public let scannedAt: Date
    public let elapsed: TimeInterval
    public var root: DiskUsageNode? { nodes[rootPath] }

    public init(rootPath: String, nodes: [String: DiskUsageNode], scannedAt: Date, elapsed: TimeInterval) {
        self.rootPath = rootPath
        self.nodes = nodes
        self.scannedAt = scannedAt
        self.elapsed = elapsed
    }

    public func children(of path: String) -> [DiskUsageNode] {
        (nodes[path]?.children ?? []).compactMap { nodes[$0] }.sorted {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path < $1.path
        }
    }

    /// Merge an on-demand expanded subtree snapshot while preserving root breadcrumbs.
    public func mergingExpandedSubtree(_ subtree: DiskUsageSnapshot) -> DiskUsageSnapshot {
        var merged = nodes
        for (key, value) in subtree.nodes {
            merged[key] = value
        }
        return DiskUsageSnapshot(rootPath: rootPath, nodes: merged, scannedAt: subtree.scannedAt, elapsed: elapsed)
    }

    /// Instantly projects an already-scanned subfolder without re-walking disk.
    public func extractingSubtree(at subRootPath: String) -> DiskUsageSnapshot? {
        let clean = PathGate.standardizeOnly(subRootPath)
        guard let subRoot = nodes[clean], !subRoot.hasTruncatedWalk else { return nil }
        if clean == rootPath { return self }
        let prefix = clean == "/" ? "/" : clean + "/"
        var extracted: [String: DiskUsageNode] = [:]
        extracted.reserveCapacity(min(nodes.count, 65_536))
        for (key, value) in nodes where key == clean || key.hasPrefix(prefix) {
            extracted[key] = value
        }
        return DiskUsageSnapshot(rootPath: clean, nodes: extracted, scannedAt: scannedAt, elapsed: 0)
    }
}

public struct DiskVolumeSpaceOverview: Equatable, Sendable {
    public let volumeName: String
    public let mountPath: String
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let availableBytes: UInt64
    public let purgeableBytes: UInt64
    public let isRootFileSystem: Bool

    public init(
        volumeName: String,
        mountPath: String,
        totalBytes: UInt64,
        usedBytes: UInt64,
        availableBytes: UInt64,
        purgeableBytes: UInt64,
        isRootFileSystem: Bool
    ) {
        self.volumeName = volumeName
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.purgeableBytes = purgeableBytes
        self.isRootFileSystem = isRootFileSystem
    }
}

public struct DiskInteractiveScanOptions: Sendable {
    public let maxDepth: Int
    public let minRetainedChildBytesAfterShallowDepth: UInt64
    public let shallowFullRetentionDepth: Int
    public let maxRetainedSmallChildrenPerDirectory: Int
    public let workerCount: Int

    public init(
        maxDepth: Int = 96,
        minRetainedChildBytesAfterShallowDepth: UInt64 = 64 * 1024,
        shallowFullRetentionDepth: Int = 3,
        maxRetainedSmallChildrenPerDirectory: Int = 24,
        workerCount: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    ) {
        self.maxDepth = max(0, maxDepth)
        self.minRetainedChildBytesAfterShallowDepth = minRetainedChildBytesAfterShallowDepth
        self.shallowFullRetentionDepth = max(0, shallowFullRetentionDepth)
        self.maxRetainedSmallChildrenPerDirectory = max(0, maxRetainedSmallChildrenPerDirectory)
        self.workerCount = max(1, workerCount)
    }
}

public struct DiskScanBudget: Sendable {
    public let maxEntries: Int
    public let maxDepth: Int
    public let maxSeconds: TimeInterval
    public init(maxEntries: Int = 60_000, maxDepth: Int = 64, maxSeconds: TimeInterval = 15) {
        self.maxEntries = max(1, maxEntries)
        self.maxDepth = max(0, maxDepth)
        self.maxSeconds = max(0, maxSeconds)
    }
}

public struct DiskUsageProgress: Sendable {
    public let entries: Int
    public let currentPath: String
    public let snapshot: DiskUsageSnapshot
}

/// Metadata-only traversal. No shell parsing, file-content reads, or deletion.
/// Dataless placeholders are skipped. The time budget is cooperative between
/// filesystem calls; a stalled volume can still delay an individual syscall.
/// Directory descriptors are opened with O_NOFOLLOW; children are inspected relative
/// to the open parent, so renames cannot redirect a walk through a replaced symlink.
public enum DiskUsageScanner {
    public static func scan(
        root: URL,
        budget: DiskScanBudget = DiskScanBudget(),
        onProgress: @Sendable (DiskUsageProgress) -> Void = { _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) -> DiskUsageSnapshot {
        let started = ContinuousClock.now
        let path = root.standardizedFileURL.path
        var nodes: [String: DiskUsageNode] = [:]
        var visited = Set<FileIdentity>()
        var count = 0
        var stop: DiskScanIssue?
        var lastEmission = started
        var discoveredChildren: [String] = []
        var observedBytes: UInt64 = 0
        var observedLogicalBytes: UInt64 = 0
        var branchBytes: [String: UInt64] = [:]
        var branchLogicalBytes: [String: UInt64] = [:]

        func emit(_ currentPath: String, force: Bool = false) {
            guard force || (count % 128 == 0 && lastEmission.duration(to: .now) >= .milliseconds(250)),
                  var root = nodes[path] else { return }
            lastEmission = .now
            let visible = Array(discoveredChildren.prefix(512))
            root.children = visible
            root.allocatedBytes = observedBytes
            root.logicalBytes = observedLogicalBytes
            root.issues.insert(.inProgress)
            var preview = Dictionary(uniqueKeysWithValues: visible.compactMap { key -> (String, DiskUsageNode)? in
                guard var child = nodes[key] else { return nil }
                child.allocatedBytes = branchBytes[key] ?? 0
                child.logicalBytes = branchLogicalBytes[key] ?? 0
                child.children = []
                child.issues.insert(.inProgress)
                return (key, child)
            })
            preview[path] = root
            onProgress(DiskUsageProgress(entries: count, currentPath: currentPath,
                snapshot: DiskUsageSnapshot(rootPath: path, nodes: preview, scannedAt: Date(), elapsed: 0)))
        }

        func interruption() -> DiskScanIssue? {
            if isCancelled() { return .cancelled }
            if started.duration(to: .now) >= .seconds(budget.maxSeconds) { return .timeLimit }
            if count >= budget.maxEntries { return .entryLimit }
            return nil
        }

        func makeNode(_ path: String, _ info: stat) -> DiskUsageNode {
            let type = info.st_mode & mode_t(S_IFMT)
            let directory = type == mode_t(S_IFDIR)
            let link = type == mode_t(S_IFLNK)
            let identity = FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
            let duplicate = !directory && info.st_nlink > 1 && !visited.insert(identity).inserted
            return DiskUsageNode(path: path, isDirectory: directory, isSymbolicLink: link,
                isHardLinkDuplicate: duplicate,
                allocatedBytes: duplicate ? 0 : UInt64(max(0, info.st_blocks)) * 512,
                logicalBytes: directory ? 0 : UInt64(max(0, info.st_size)),
                hardLinkBytesCountedElsewhere: duplicate ? UInt64(max(0, info.st_blocks)) * 512 : 0,
                children: [], issues: [])
        }

        func walk(_ fd: Int32, path: String, depth: Int, device: dev_t, branch: String? = nil) {
            // fdopendir takes ownership of fd, including when a task is cancelled.
            guard let directory = fdopendir(fd) else {
                close(fd)
                nodes[path]?.issues.insert(.unreadable)
                return
            }
            defer { closedir(directory) }
            let parentFD = dirfd(directory)
            while true {
                if let issue = stop ?? interruption() {
                    stop = issue
                    nodes[path]?.issues.insert(issue)
                    break
                }
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { nodes[path]?.issues.insert(.unreadable) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                count += 1
                emit(childPath)
                var info = stat()
                guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    nodes[path]?.issues.insert(errno == ENOENT ? .changed : .unreadable)
                    continue
                }
                nodes[childPath] = makeNode(childPath, info)
                nodes[path]?.children.append(childPath)
                let owner = branch ?? childPath
                if depth == 0 { discoveredChildren.append(childPath) }
                if info.st_dev == device {
                    let bytes = nodes[childPath]?.allocatedBytes ?? 0
                    observedBytes += bytes
                    branchBytes[owner, default: 0] += bytes
                    let logical = nodes[childPath]?.logicalBytes ?? 0
                    observedLogicalBytes += logical
                    branchLogicalBytes[owner, default: 0] += logical
                }
                if info.st_dev != device {
                    nodes[childPath]?.allocatedBytes = 0
                    nodes[childPath]?.logicalBytes = 0
                    nodes[childPath]?.issues.insert(.otherVolume)
                } else if info.st_flags & UInt32(SF_DATALESS) != 0 {
                    nodes[childPath]?.issues.insert(.cloudPlaceholder)
                } else if nodes[childPath]?.isDirectory == true {
                    if depth >= budget.maxDepth {
                        nodes[childPath]?.issues.insert(.depthLimit)
                    } else {
                        let childFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        if childFD < 0 {
                            nodes[childPath]?.issues.insert(.unreadable)
                        } else {
                            var opened = stat()
                            if fstat(childFD, &opened) != 0 || opened.st_dev != info.st_dev || opened.st_ino != info.st_ino {
                                close(childFD)
                                nodes[childPath]?.issues.insert(.changed)
                            } else {
                                walk(childFD, path: childPath, depth: depth + 1, device: device, branch: owner)
                            }
                        }
                    }
                }
                if let child = nodes[childPath] {
                    nodes[path]?.allocatedBytes += child.allocatedBytes
                    nodes[path]?.logicalBytes += child.logicalBytes
                    nodes[path]?.hardLinkBytesCountedElsewhere += child.hardLinkBytesCountedElsewhere
                    nodes[path]?.issues.formUnion(child.issues)
                }
                if depth == 0 { emit(childPath) }
            }
        }

        var rootInfo = stat()
        if lstat(path, &rootInfo) == 0 {
            nodes[path] = makeNode(path, rootInfo)
            observedBytes = nodes[path]?.allocatedBytes ?? 0
            observedLogicalBytes = nodes[path]?.logicalBytes ?? 0
            emit(path, force: true)
            if rootInfo.st_flags & UInt32(SF_DATALESS) != 0 {
                nodes[path]?.issues.insert(.cloudPlaceholder)
            } else if nodes[path]?.isDirectory == true {
                let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var opened = stat()
                if fd < 0 { nodes[path]?.issues.insert(.unreadable) }
                else if fstat(fd, &opened) != 0 || opened.st_ino != rootInfo.st_ino || opened.st_dev != rootInfo.st_dev {
                    close(fd)
                    nodes[path]?.issues.insert(.changed)
                } else {
                    walk(fd, path: path, depth: 0, device: rootInfo.st_dev)
                }
            }
        } else {
            nodes[path] = DiskUsageNode(path: path, isDirectory: true, isSymbolicLink: false,
                isHardLinkDuplicate: false, allocatedBytes: 0, logicalBytes: 0, hardLinkBytesCountedElsewhere: 0,
                children: [], issues: [.unreadable])
        }
        emit(path, force: true)
        let duration = started.duration(to: .now).components
        return DiskUsageSnapshot(rootPath: path, nodes: nodes, scannedAt: Date(),
            elapsed: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }

    /// Allocation-free directory/file byte accumulator sharing the exact same safety boundaries
    /// (O_NOFOLLOW, mount-point guard, hard-link deduplication, dataless placeholder detection,
    /// and entry/depth/time budgets) without constructing `DiskUsageNode` trees or child arrays.
    public static func sumAllocatedBytes(
        root: URL,
        budget: DiskScanBudget = .init(),
        isCancelled: () -> Bool = { false }
    ) -> (allocatedBytes: UInt64, isComplete: Bool) {
        let measured = sumAllocatedBytesCountingEntries(root: root, budget: budget, isCancelled: isCancelled)
        return (measured.allocatedBytes, measured.isComplete)
    }

    static func sumAllocatedBytesCountingEntries(
        root: URL,
        budget: DiskScanBudget = .init(),
        isCancelled: () -> Bool = { false }
    ) -> (allocatedBytes: UInt64, isComplete: Bool, entriesVisited: Int) {
        let started = ContinuousClock.now
        let path = root.standardizedFileURL.path
        var visited = Set<FileIdentity>()
        var count = 0
        var totalBytes: UInt64 = 0
        var isComplete = true
        var stopped = false

        func shouldStop() -> Bool {
            if isCancelled() { return true }
            if started.duration(to: .now) >= .seconds(budget.maxSeconds) { return true }
            if count >= budget.maxEntries { return true }
            return false
        }

        func walkSum(_ fd: Int32, depth: Int, device: dev_t) {
            guard let directory = fdopendir(fd) else {
                close(fd)
                isComplete = false
                return
            }
            defer { closedir(directory) }
            let parentFD = dirfd(directory)

            while true {
                if stopped || shouldStop() {
                    stopped = true
                    isComplete = false
                    break
                }
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { isComplete = false }
                    break
                }
                let namlen = Int(entry.pointee.d_namlen)
                var childFDToWalk: Int32 = -1
                withUnsafePointer(to: &entry.pointee.d_name) { nameTuplePtr in
                    nameTuplePtr.withMemoryRebound(to: CChar.self, capacity: namlen + 1) { cName in
                        if namlen == 1 && cName[0] == 0x2E { return }
                        if namlen == 2 && cName[0] == 0x2E && cName[1] == 0x2E { return }

                        count += 1
                        var info = stat()
                        guard fstatat(parentFD, cName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                            isComplete = false
                            return
                        }
                        guard info.st_dev == device else {
                            isComplete = false
                            return
                        }
                        let type = info.st_mode & mode_t(S_IFMT)
                        let isDirectory = type == mode_t(S_IFDIR)
                        let identity = FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
                        let duplicate = !isDirectory && info.st_nlink > 1 && !visited.insert(identity).inserted
                        if !duplicate {
                            totalBytes &+= UInt64(max(0, info.st_blocks)) * 512
                        }
                        if info.st_flags & UInt32(SF_DATALESS) != 0 {
                            isComplete = false
                        } else if isDirectory {
                            if depth >= budget.maxDepth {
                                isComplete = false
                            } else {
                                let openedFD = openat(parentFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                                if openedFD < 0 {
                                    isComplete = false
                                } else {
                                    var opened = stat()
                                    if fstat(openedFD, &opened) != 0 || opened.st_dev != info.st_dev || opened.st_ino != info.st_ino {
                                        close(openedFD)
                                        isComplete = false
                                    } else {
                                        childFDToWalk = openedFD
                                    }
                                }
                            }
                        }
                    }
                }
                if childFDToWalk >= 0 {
                    walkSum(childFDToWalk, depth: depth + 1, device: device)
                }
            }
        }

        var rootInfo = stat()
        guard lstat(path, &rootInfo) == 0 else {
            return (0, false, 0)
        }
        let rootType = rootInfo.st_mode & mode_t(S_IFMT)
        let rootIsDirectory = rootType == mode_t(S_IFDIR)
        let rootIdentity = FileIdentity(device: UInt64(rootInfo.st_dev), inode: UInt64(rootInfo.st_ino))
        let rootDuplicate = !rootIsDirectory && rootInfo.st_nlink > 1 && !visited.insert(rootIdentity).inserted
        if !rootDuplicate {
            totalBytes &+= UInt64(max(0, rootInfo.st_blocks)) * 512
        }
        if rootInfo.st_flags & UInt32(SF_DATALESS) != 0 {
            isComplete = false
        } else if rootIsDirectory {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                isComplete = false
            } else {
                var opened = stat()
                if fstat(fd, &opened) != 0 || opened.st_ino != rootInfo.st_ino || opened.st_dev != rootInfo.st_dev {
                    close(fd)
                    isComplete = false
                } else {
                    walkSum(fd, depth: 0, device: rootInfo.st_dev)
                }
            }
        }
        return (totalBytes, isComplete, count)
    }

    // MARK: - Volume Overview & Full Disk Access Probe

    /// Instantaneous, zero-traversal volume accounting matching macOS Storage settings.
    public static func volumeOverview(for targetURL: URL = URL(fileURLWithPath: "/")) -> DiskVolumeSpaceOverview? {
        var candidate = URL(fileURLWithPath: PathGate.standardizeOnly(targetURL.path))
        let fm = FileManager.default
        while candidate.path != "/" && !fm.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        let keys: Set<URLResourceKey> = [
            .volumeURLKey,
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRootFileSystemKey
        ]
        guard let values = try? candidate.resourceValues(forKeys: keys),
              let rawTotal = values.volumeTotalCapacity, rawTotal > 0 else {
            return nil
        }
        let total = UInt64(rawTotal)
        let basicFree = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        let importantFreeRaw = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? basicFree
        let importantFree = min(total, max(basicFree, importantFreeRaw))
        let purgeable = importantFree >= basicFree ? (importantFree - basicFree) : 0
        let used = total >= importantFree ? (total - importantFree) : 0
        let mountPath = values.volume?.path ?? "/"
        let isRoot = values.volumeIsRootFileSystem ?? (mountPath == "/")
        let defaultName = isRoot ? "Macintosh HD" : URL(fileURLWithPath: mountPath).lastPathComponent
        let rawName = values.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DiskVolumeSpaceOverview(
            volumeName: rawName.isEmpty ? defaultName : rawName,
            mountPath: mountPath,
            totalBytes: total,
            usedBytes: used,
            availableBytes: min(total, basicFree),
            purgeableBytes: purgeable,
            isRootFileSystem: isRoot
        )
    }

    /// Lists user-facing mounted local volumes (boot volume + external drives, skipping hidden APFS helper volumes).
    public static func mountedLocalVolumes() -> [DiskVolumeSpaceOverview] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey],
            options: [.skipHiddenVolumes]
        ) ?? [URL(fileURLWithPath: "/")]
        var seen: Set<String> = []
        var list: [DiskVolumeSpaceOverview] = []
        for url in urls {
            guard let ov = volumeOverview(for: url) else { continue }
            if ov.mountPath.hasPrefix("/System/Volumes/") { continue }
            if seen.insert(ov.mountPath).inserted {
                list.append(ov)
            }
        }
        if list.isEmpty, let root = volumeOverview() {
            list.append(root)
        }
        list.sort {
            if $0.isRootFileSystem != $1.isRootFileSystem { return $0.isRootFileSystem }
            return $0.volumeName.localizedStandardCompare($1.volumeName) == .orderedAscending
        }
        return list
    }

    /// Read-only, non-prompting Full Disk Access probe. Opens only the descriptor
    /// with O_NOFOLLOW and immediately closes it without reading a single byte.
    public static func hasFullDiskAccess() -> Bool {
        let systemTCC = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(systemTCC, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return true
        }
        if errno == EPERM || errno == EACCES {
            return false
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for fallback in [home + "/Library/TCC/TCC.db", home + "/Library/Safari"] {
            let subFD = open(fallback, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if subFD >= 0 {
                close(subFD)
                return true
            }
            if errno == EPERM || errno == EACCES {
                return false
            }
        }
        return true
    }

    // MARK: - Parallel Full-Tree Scanner (getattrlistbulk + APFS Firmlink Deduplication)

    private static let syntheticSkippedPaths: Set<String> = [
        "/.vol", "/.nofollow", "/.resolve", "/dev", "/Network", "/net", "/home"
    ]

    private static let priorityDirectoryNames: [String: Int] = [
        "Users": 0, "Applications": 1, "Library": 2, "System": 3, "private": 4, "opt": 5, "usr": 6,
        "Downloads": 7, "Desktop": 8, "Documents": 9, "Movies": 10, "Pictures": 11, "Music": 12,
        ".ollama": 13, ".cache": 14, ".nvm": 15, ".cargo": 16, ".docker": 17, ".gemini": 18
    ]

    /// High-throughput interactive scanner for DiskMapView. Uses `getattrlistbulk`
    /// across a bounded worker pool with at most 1 open directory FD per worker,
    /// no artificial 60k/15s cutoff, and APFS firmlink directory deduplication.
    public static func scanInteractive(
        root: URL,
        options: DiskInteractiveScanOptions = .init(),
        seedSubtrees: [DiskUsageSnapshot] = [],
        onProgress: @Sendable (DiskUsageProgress) -> Void = { _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) -> DiskUsageSnapshot {
        let started = ContinuousClock.now
        let rootPath = PathGate.standardizeOnly(root.path)

        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0 else {
            let missing = DiskUsageNode(
                path: rootPath, isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
                allocatedBytes: 0, logicalBytes: 0, hardLinkBytesCountedElsewhere: 0,
                children: [], issues: [.unreadable]
            )
            return DiskUsageSnapshot(rootPath: rootPath, nodes: [rootPath: missing], scannedAt: Date(), elapsed: 0)
        }

        let rootMode = rootInfo.st_mode & mode_t(S_IFMT)
        let rootIsDir = rootMode == mode_t(S_IFDIR)
        let rootIsLink = rootMode == mode_t(S_IFLNK)
        let rootInitialAlloc = UInt64(max(0, rootInfo.st_blocks)) * 512
        let rootInitialLogical = rootIsDir ? 0 : UInt64(max(0, rootInfo.st_size))

        if isCancelled() {
            let cancelledNode = DiskUsageNode(
                path: rootPath, isDirectory: rootIsDir, isSymbolicLink: rootIsLink, isHardLinkDuplicate: false,
                allocatedBytes: rootInitialAlloc, logicalBytes: rootInitialLogical, hardLinkBytesCountedElsewhere: 0,
                children: [], issues: [.cancelled]
            )
            return DiskUsageSnapshot(rootPath: rootPath, nodes: [rootPath: cancelledNode], scannedAt: Date(), elapsed: 0)
        }

        if rootInfo.st_flags & UInt32(SF_DATALESS) != 0 || !rootIsDir {
            var issues: Set<DiskScanIssue> = []
            if rootInfo.st_flags & UInt32(SF_DATALESS) != 0 { issues.insert(.cloudPlaceholder) }
            let single = DiskUsageNode(
                path: rootPath, isDirectory: rootIsDir, isSymbolicLink: rootIsLink, isHardLinkDuplicate: false,
                allocatedBytes: rootInitialAlloc, logicalBytes: rootInitialLogical, hardLinkBytesCountedElsewhere: 0,
                children: [], issues: issues
            )
            return DiskUsageSnapshot(rootPath: rootPath, nodes: [rootPath: single], scannedAt: Date(), elapsed: 0)
        }

        var validSeeds: [DiskUsageSnapshot] = []
        let sortedCandidates = seedSubtrees.sorted { $0.rootPath.count < $1.rootPath.count }
        for candidate in sortedCandidates {
            let cleanSeed = PathGate.standardizeOnly(candidate.rootPath)
            guard cleanSeed != rootPath,
                  let seedRoot = candidate.root,
                  seedRoot.isDirectory,
                  !seedRoot.hasTruncatedWalk,
                  rootPath == "/" ? cleanSeed.hasPrefix("/") : cleanSeed.hasPrefix(rootPath + "/") else {
                continue
            }
            let overlapsOuterSeed = validSeeds.contains { outer in
                let outerClean = PathGate.standardizeOnly(outer.rootPath)
                return cleanSeed == outerClean || cleanSeed.hasPrefix(outerClean + "/")
            }
            if !overlapsOuterSeed {
                validSeeds.append(candidate)
            }
        }
        let seedMap = Dictionary(uniqueKeysWithValues: validSeeds.map { (PathGate.standardizeOnly($0.rootPath), $0) })

        return withoutActuallyEscaping(onProgress) { escapingProgress in
            withoutActuallyEscaping(isCancelled) { escapingCancelled in
                let coordinator = InteractiveWalkCoordinator(
                    rootPath: rootPath,
                    rootStat: rootInfo,
                    options: options,
                    seedByRootPath: seedMap,
                    onProgress: escapingProgress,
                    isCancelled: escapingCancelled
                )
                return coordinator.run(started: started)
            }
        }
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private final class InteractiveWalkCoordinator: @unchecked Sendable {
        private struct DirTask {
            let recordIndex: Int
            let path: String
            let depth: Int
            let expectedIdentity: FileIdentity?
            let topBranchIndex: Int
        }

        private struct DirRecord {
            let path: String
            let parentIndex: Int
            let depth: Int
            var ownAllocatedBytes: UInt64
            var ownLogicalBytes: UInt64
            var ownHardLinkElsewhere: UInt64
            var liveAllocatedBytes: UInt64
            var liveLogicalBytes: UInt64
            var childDirIndices: [Int] = []
            var retainedFileNodes: [DiskUsageNode] = []
            var issues: Set<DiskScanIssue> = []
            var hasOmittedSmallChildren = false
            var visited = false
        }

        private struct ParsedEntry {
            let name: String
            let error: UInt32
            let dev: dev_t
            let objType: UInt32
            let flags: UInt32
            let fileID: UInt64
            let mountStatus: UInt32
            let linkCount: UInt32
            let totalSize: Int64
            let allocSize: Int64
        }

        private let rootPath: String
        private let rootDevice: dev_t
        private let rootIdentity: FileIdentity
        private let options: DiskInteractiveScanOptions
        private let seedByRootPath: [String: DiskUsageSnapshot]
        private let onProgress: @Sendable (DiskUsageProgress) -> Void
        private let isCancelled: @Sendable () -> Bool

        private let condition = NSCondition()
        private var shallowQueue: [DirTask] = []
        private var shallowHead = 0
        private var deepStack: [DirTask] = []
        private var deferredPhaseTwo: [DirTask] = []
        private var inFlight = 0
        private var wasCancelled = false

        private var dirRecords: [DirRecord] = []
        private var mountedSeeds: [DiskUsageSnapshot] = []
        private var mountedSeedsByPath: [String: DiskUsageSnapshot] = [:]
        private var topBranchPaths: [String] = []
        private var topBranchIsDir: [Bool] = []
        private var topBranchIsLink: [Bool] = []
        private var topBranchAllocated: [UInt64] = []
        private var topBranchLogical: [UInt64] = []
        private var totalEntries = 0
        private var totalObservedAllocated: UInt64 = 0
        private var totalObservedLogical: UInt64 = 0
        private var lastEmission = ContinuousClock.now

        private let visitedDirsLock = NSLock()
        private var visitedDirectories: Set<FileIdentity> = []

        private let hardLinkLock = NSLock()
        private var visitedHardLinks: Set<FileIdentity> = []

        init(
            rootPath: String,
            rootStat: stat,
            options: DiskInteractiveScanOptions,
            seedByRootPath: [String: DiskUsageSnapshot],
            onProgress: @escaping @Sendable (DiskUsageProgress) -> Void,
            isCancelled: @escaping @Sendable () -> Bool
        ) {
            self.rootPath = rootPath
            self.rootDevice = rootStat.st_dev
            self.rootIdentity = FileIdentity(device: UInt64(rootStat.st_dev), inode: UInt64(rootStat.st_ino))
            self.options = options
            self.seedByRootPath = seedByRootPath
            self.onProgress = onProgress
            self.isCancelled = isCancelled

            let rootAlloc = UInt64(max(0, rootStat.st_blocks)) * 512
            self.dirRecords = [
                DirRecord(
                    path: rootPath,
                    parentIndex: -1,
                    depth: 0,
                    ownAllocatedBytes: rootAlloc,
                    ownLogicalBytes: 0,
                    ownHardLinkElsewhere: 0,
                    liveAllocatedBytes: rootAlloc,
                    liveLogicalBytes: 0
                )
            ]
            self.totalObservedAllocated = rootAlloc
            self.shallowQueue = [
                DirTask(
                    recordIndex: 0,
                    path: rootPath,
                    depth: 0,
                    expectedIdentity: rootIdentity,
                    topBranchIndex: -1
                )
            ]
        }

        func run(started: ContinuousClock.Instant) -> DiskUsageSnapshot {
            emitProgressSnapshot(currentPath: rootPath, force: true)

            let workers = max(1, options.workerCount)
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                let bufferSize = 64 * 1024
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
                defer { buffer.deallocate() }
                while let task = self.nextTask() {
                    self.processDirectory(task, buffer: buffer, bufferSize: bufferSize)
                }
            }

            let finalized = buildFinalSnapshot(started: started)
            emitFinalProgress(from: finalized)
            return finalized
        }

        private func nextTask() -> DirTask? {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if isCancelled() {
                    wasCancelled = true
                    shallowQueue.removeAll()
                    shallowHead = 0
                    deepStack.removeAll()
                    deferredPhaseTwo.removeAll()
                    condition.broadcast()
                    return nil
                }
                if shallowHead < shallowQueue.count {
                    let task = shallowQueue[shallowHead]
                    shallowHead += 1
                    if shallowHead > 256 && shallowHead * 2 >= shallowQueue.count {
                        shallowQueue.removeFirst(shallowHead)
                        shallowHead = 0
                    }
                    inFlight += 1
                    return task
                }
                if let task = deepStack.popLast() {
                    inFlight += 1
                    return task
                }
                if inFlight == 0 {
                    if !deferredPhaseTwo.isEmpty {
                        shallowQueue = deferredPhaseTwo
                        shallowHead = 0
                        deferredPhaseTwo.removeAll()
                        condition.broadcast()
                        continue
                    }
                    condition.broadcast()
                    return nil
                }
                condition.wait()
            }
        }

        private func claimDirectoryIdentity(_ identity: FileIdentity) -> Bool {
            visitedDirsLock.lock()
            defer { visitedDirsLock.unlock() }
            return visitedDirectories.insert(identity).inserted
        }

        private func claimHardLinkIdentity(_ identity: FileIdentity) -> Bool {
            hardLinkLock.lock()
            defer { hardLinkLock.unlock() }
            return visitedHardLinks.insert(identity).inserted
        }

        private func processDirectory(_ task: DirTask, buffer: UnsafeMutableRawPointer, bufferSize: Int) {
            var localIssues: Set<DiskScanIssue> = []
            var localEntriesCount = 0
            var ownAllocDelta: UInt64 = 0
            var ownLogicalDelta: UInt64 = 0
            var ownHardLinkDelta: UInt64 = 0
            var keptFiles: [DiskUsageNode] = []
            var smallFileCandidates: [DiskUsageNode] = []
            var omittedSmall = false
            var discoveredSubdirs: [(name: String, path: String, expectedIdentity: FileIdentity?, issues: Set<DiskScanIssue>, shouldDescend: Bool, deferPhaseTwo: Bool)] = []

            let fd = open(task.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                localIssues.insert(errno == ENOENT ? .changed : .unreadable)
                finishDirectory(
                    task: task, entriesRead: 0, ownAllocDelta: 0, ownLogicalDelta: 0, ownHardLinkDelta: 0,
                    keptFiles: [], omittedSmall: false, localIssues: localIssues, subdirs: []
                )
                return
            }

            var openedStat = stat()
            if fstat(fd, &openedStat) != 0 {
                close(fd)
                localIssues.insert(.unreadable)
                finishDirectory(
                    task: task, entriesRead: 0, ownAllocDelta: 0, ownLogicalDelta: 0, ownHardLinkDelta: 0,
                    keptFiles: [], omittedSmall: false, localIssues: localIssues, subdirs: []
                )
                return
            }

            if openedStat.st_dev != rootDevice {
                close(fd)
                localIssues.insert(.otherVolume)
                finishDirectory(
                    task: task, entriesRead: 0, ownAllocDelta: 0, ownLogicalDelta: 0, ownHardLinkDelta: 0,
                    keptFiles: [], omittedSmall: false, localIssues: localIssues, subdirs: []
                )
                return
            }

            let actualIdentity = FileIdentity(device: UInt64(openedStat.st_dev), inode: UInt64(openedStat.st_ino))
            if let expected = task.expectedIdentity, expected != actualIdentity {
                close(fd)
                localIssues.insert(.changed)
                finishDirectory(
                    task: task, entriesRead: 0, ownAllocDelta: 0, ownLogicalDelta: 0, ownHardLinkDelta: 0,
                    keptFiles: [], omittedSmall: false, localIssues: localIssues, subdirs: []
                )
                return
            }

            if rootPath == "/", task.path.hasPrefix("/System/Volumes/Data/") {
                let canonicalCandidate = String(task.path.dropFirst("/System/Volumes/Data".count))
                if !canonicalCandidate.isEmpty, !DiskUsageScanner.syntheticSkippedPaths.contains(canonicalCandidate) {
                    var canonStat = stat()
                    if lstat(canonicalCandidate, &canonStat) == 0,
                       canonStat.st_dev == openedStat.st_dev,
                       canonStat.st_ino == openedStat.st_ino {
                        // Canonical firmlink on / (e.g. /Users, /Applications, /Library, /private) owns this subtree.
                        close(fd)
                        finishDirectory(
                            task: task, entriesRead: 0, ownAllocDelta: 0, ownLogicalDelta: 0, ownHardLinkDelta: 0,
                            keptFiles: [], omittedSmall: false, localIssues: [], subdirs: []
                        )
                        return
                    }
                }
            }

            if !claimDirectoryIdentity(actualIdentity) {
                // Already traversed via its primary APFS firmlink path (e.g. /Users vs /System/Volumes/Data/Users).
                close(fd)
                finishDirectory(
                    task: task, entriesRead: 0, ownAllocDelta: 0, ownLogicalDelta: 0, ownHardLinkDelta: 0,
                    keptFiles: [], omittedSmall: false, localIssues: [], subdirs: []
                )
                return
            }

            if let seed = seedByRootPath[task.path], let seedRoot = seed.root {
                close(fd)
                mountSeedDirectory(task: task, seed: seed, seedRoot: seedRoot)
                return
            }

            let rawEntries = readDirectoryEntries(fd: fd, buffer: buffer, bufferSize: bufferSize, issues: &localIssues)
            // Close FD immediately before processing children so at most 1 FD is open per worker thread.
            close(fd)

            var entries = rawEntries
            if task.depth <= 2 {
                entries.sort { lhs, rhs in
                    let rankL = DiskUsageScanner.priorityDirectoryNames[lhs.name] ?? 100
                    let rankR = DiskUsageScanner.priorityDirectoryNames[rhs.name] ?? 100
                    if rankL != rankR { return rankL < rankR }
                    return lhs.name < rhs.name
                }
            }

            for item in entries {
                if isCancelled() {
                    localIssues.insert(.cancelled)
                    break
                }
                if item.name == "." || item.name == ".." { continue }
                localEntriesCount += 1

                if item.error != 0 {
                    localIssues.insert(item.error == UInt32(ENOENT) ? .changed : .unreadable)
                    continue
                }

                let childPath = task.path == "/" ? "/\(item.name)" : "\(task.path)/\(item.name)"

                if item.objType == VDIR.rawValue {
                    if DiskUsageScanner.syntheticSkippedPaths.contains(childPath) {
                        continue
                    }

                    var subIssues: Set<DiskScanIssue> = []
                    var shouldDescend = true
                    var expectedSubIdentity: FileIdentity? = FileIdentity(device: UInt64(item.dev), inode: item.fileID)

                    if item.mountStatus != 0 || (item.flags & UInt32(SF_FIRMLINK)) != 0 || item.dev != rootDevice {
                        var targetStat = stat()
                        if lstat(childPath, &targetStat) != 0 {
                            subIssues.insert(errno == ENOENT ? .changed : .unreadable)
                            shouldDescend = false
                        } else if (targetStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                            let symlinkNode = DiskUsageNode(
                                path: childPath, isDirectory: false, isSymbolicLink: true, isHardLinkDuplicate: false,
                                allocatedBytes: 0, logicalBytes: UInt64(max(0, targetStat.st_size)),
                                hardLinkBytesCountedElsewhere: 0, children: [], issues: []
                            )
                            if task.depth <= options.shallowFullRetentionDepth {
                                keptFiles.append(symlinkNode)
                            } else {
                                omittedSmall = true
                            }
                            continue
                        } else if targetStat.st_dev != rootDevice {
                            subIssues.insert(.otherVolume)
                            shouldDescend = false
                        } else if targetStat.st_flags & UInt32(SF_DATALESS) != 0 {
                            subIssues.insert(.cloudPlaceholder)
                            shouldDescend = false
                        } else {
                            expectedSubIdentity = FileIdentity(device: UInt64(targetStat.st_dev), inode: UInt64(targetStat.st_ino))
                        }
                    } else if item.flags & UInt32(SF_DATALESS) != 0 {
                        subIssues.insert(.cloudPlaceholder)
                        shouldDescend = false
                    }

                    if shouldDescend && task.depth >= options.maxDepth {
                        subIssues.insert(.depthLimit)
                        shouldDescend = false
                    }

                    let deferToPhaseTwo = false
                    discoveredSubdirs.append((
                        name: item.name,
                        path: childPath,
                        expectedIdentity: expectedSubIdentity,
                        issues: subIssues,
                        shouldDescend: shouldDescend,
                        deferPhaseTwo: deferToPhaseTwo
                    ))
                } else {
                    let isSymlink = item.objType == VLNK.rawValue
                    if item.dev != rootDevice {
                        if task.depth <= options.shallowFullRetentionDepth {
                            keptFiles.append(DiskUsageNode(
                                path: childPath, isDirectory: false, isSymbolicLink: isSymlink, isHardLinkDuplicate: false,
                                allocatedBytes: 0, logicalBytes: 0, hardLinkBytesCountedElsewhere: 0,
                                children: [], issues: [.otherVolume]
                            ))
                        }
                        continue
                    }

                    let rawAlloc = UInt64(max(0, item.allocSize))
                    let logical = UInt64(max(0, item.totalSize))
                    let isHardLinkDup = !isSymlink && item.linkCount > 1 &&
                        !claimHardLinkIdentity(FileIdentity(device: UInt64(item.dev), inode: item.fileID))
                    let alloc = isHardLinkDup ? 0 : rawAlloc
                    let hardElsewhere = isHardLinkDup ? rawAlloc : 0

                    ownAllocDelta &+= alloc
                    ownLogicalDelta &+= logical
                    ownHardLinkDelta &+= hardElsewhere

                    var fileIssues: Set<DiskScanIssue> = []
                    if item.flags & UInt32(SF_DATALESS) != 0 {
                        fileIssues.insert(.cloudPlaceholder)
                    }

                    if task.depth <= options.shallowFullRetentionDepth ||
                        alloc >= options.minRetainedChildBytesAfterShallowDepth ||
                        !fileIssues.isEmpty ||
                        isHardLinkDup {
                        keptFiles.append(DiskUsageNode(
                            path: childPath, isDirectory: false, isSymbolicLink: isSymlink,
                            isHardLinkDuplicate: isHardLinkDup, allocatedBytes: alloc, logicalBytes: logical,
                            hardLinkBytesCountedElsewhere: hardElsewhere, children: [], issues: fileIssues
                        ))
                    } else if task.depth <= 4 && options.maxRetainedSmallChildrenPerDirectory > 0 {
                        let candidate = DiskUsageNode(
                            path: childPath, isDirectory: false, isSymbolicLink: isSymlink,
                            isHardLinkDuplicate: false, allocatedBytes: alloc, logicalBytes: logical,
                            hardLinkBytesCountedElsewhere: 0, children: [], issues: []
                        )
                        if smallFileCandidates.count < options.maxRetainedSmallChildrenPerDirectory {
                            smallFileCandidates.append(candidate)
                        } else if let minIdx = smallFileCandidates.indices.min(by: {
                            smallFileCandidates[$0].allocatedBytes < smallFileCandidates[$1].allocatedBytes
                        }) {
                            omittedSmall = true
                            if candidate.allocatedBytes > smallFileCandidates[minIdx].allocatedBytes {
                                smallFileCandidates[minIdx] = candidate
                            }
                        }
                    } else {
                        omittedSmall = true
                    }
                }
            }

            if !smallFileCandidates.isEmpty {
                keptFiles.append(contentsOf: smallFileCandidates)
            }

            finishDirectory(
                task: task,
                entriesRead: localEntriesCount,
                ownAllocDelta: ownAllocDelta,
                ownLogicalDelta: ownLogicalDelta,
                ownHardLinkDelta: ownHardLinkDelta,
                keptFiles: keptFiles,
                omittedSmall: omittedSmall,
                localIssues: localIssues,
                subdirs: discoveredSubdirs
            )
        }

        private func readDirectoryEntries(
            fd: Int32,
            buffer: UnsafeMutableRawPointer,
            bufferSize: Int,
            issues: inout Set<DiskScanIssue>
        ) -> [ParsedEntry] {
            var attrList = attrlist()
            attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            attrList.commonattr =
                attrgroup_t(bitPattern: Int32(bitPattern: ATTR_CMN_RETURNED_ATTRS)) |
                attrgroup_t(ATTR_CMN_ERROR) |
                attrgroup_t(ATTR_CMN_NAME) |
                attrgroup_t(ATTR_CMN_DEVID) |
                attrgroup_t(ATTR_CMN_OBJTYPE) |
                attrgroup_t(ATTR_CMN_FLAGS) |
                attrgroup_t(ATTR_CMN_FILEID)
            attrList.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
            attrList.fileattr =
                attrgroup_t(ATTR_FILE_LINKCOUNT) |
                attrgroup_t(ATTR_FILE_TOTALSIZE) |
                attrgroup_t(ATTR_FILE_ALLOCSIZE)

            var results: [ParsedEntry] = []
            while true {
                if isCancelled() {
                    issues.insert(.cancelled)
                    break
                }
                errno = 0
                let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, UInt64(FSOPT_NOFOLLOW))
                if count == 0 {
                    break
                }
                if count < 0 {
                    if errno == ENOTSUP || errno == EINVAL {
                        return readDirectoryEntriesFallback(fd: fd, issues: &issues)
                    }
                    issues.insert(.unreadable)
                    break
                }

                var entryOffset = 0
                for _ in 0..<count {
                    guard entryOffset + 24 <= bufferSize else { break }
                    let entryPtr = buffer.advanced(by: entryOffset)
                    let length = Int(entryPtr.load(as: UInt32.self))
                    guard length >= 24, entryOffset + length <= bufferSize else { break }

                    var cursor = 4
                    let returned = entryPtr.load(fromByteOffset: cursor, as: attribute_set_t.self)
                    cursor += MemoryLayout<attribute_set_t>.size

                    var entryErr: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0, cursor + 4 <= length {
                        entryErr = entryPtr.load(fromByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                    }

                    var name = ""
                    if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0,
                       cursor + MemoryLayout<attrreference_t>.size <= length {
                        let ref = entryPtr.load(fromByteOffset: cursor, as: attrreference_t.self)
                        let nameOffset = cursor + Int(ref.attr_dataoffset)
                        if nameOffset >= 0, nameOffset < length {
                            let cPtr = entryPtr.advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
                            name = String(cString: cPtr)
                        }
                        cursor += MemoryLayout<attrreference_t>.size
                    }

                    if entryErr != 0 {
                        results.append(ParsedEntry(
                            name: name, error: entryErr, dev: 0, objType: 0, flags: 0,
                            fileID: 0, mountStatus: 0, linkCount: 1, totalSize: 0, allocSize: 0
                        ))
                        entryOffset += length
                        continue
                    }

                    var dev: dev_t = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0, cursor + 4 <= length {
                        dev = entryPtr.load(fromByteOffset: cursor, as: dev_t.self)
                        cursor += 4
                    }
                    var objType: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0, cursor + 4 <= length {
                        objType = entryPtr.load(fromByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                    }
                    var flags: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0, cursor + 4 <= length {
                        flags = entryPtr.load(fromByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                    }
                    var fileID: UInt64 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0, cursor + 8 <= length {
                        fileID = entryPtr.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
                        cursor += 8
                    }
                    var mntStatus: UInt32 = 0
                    if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0, cursor + 4 <= length {
                        mntStatus = entryPtr.load(fromByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                    }
                    var linkCount: UInt32 = 1
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0, cursor + 4 <= length {
                        linkCount = entryPtr.load(fromByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                    }
                    var totalSize: Int64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0, cursor + 8 <= length {
                        totalSize = entryPtr.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
                        cursor += 8
                    }
                    var allocSize: Int64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0, cursor + 8 <= length {
                        allocSize = entryPtr.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
                        cursor += 8
                    }

                    results.append(ParsedEntry(
                        name: name, error: 0, dev: dev, objType: objType, flags: flags,
                        fileID: fileID, mountStatus: mntStatus, linkCount: linkCount,
                        totalSize: totalSize, allocSize: allocSize
                    ))
                    entryOffset += length
                }
            }
            return results
        }

        private func readDirectoryEntriesFallback(fd: Int32, issues: inout Set<DiskScanIssue>) -> [ParsedEntry] {
            let dupFD = dup(fd)
            guard dupFD >= 0, let dir = fdopendir(dupFD) else {
                if dupFD >= 0 { close(dupFD) }
                issues.insert(.unreadable)
                return []
            }
            defer { closedir(dir) }
            let dirFD = dirfd(dir)
            lseek(dirFD, 0, SEEK_SET)
            var results: [ParsedEntry] = []
            while true {
                if isCancelled() {
                    issues.insert(.cancelled)
                    break
                }
                errno = 0
                guard let entry = readdir(dir) else {
                    if errno != 0 { issues.insert(.unreadable) }
                    break
                }
                let namlen = Int(entry.pointee.d_namlen)
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: namlen + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var st = stat()
                if fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                    results.append(ParsedEntry(
                        name: name, error: UInt32(errno), dev: 0, objType: 0, flags: 0,
                        fileID: 0, mountStatus: 0, linkCount: 1, totalSize: 0, allocSize: 0
                    ))
                    continue
                }
                let mode = st.st_mode & mode_t(S_IFMT)
                let objType: UInt32 = mode == mode_t(S_IFDIR) ? VDIR.rawValue : (mode == mode_t(S_IFLNK) ? VLNK.rawValue : VREG.rawValue)
                results.append(ParsedEntry(
                    name: name, error: 0, dev: st.st_dev, objType: objType, flags: st.st_flags,
                    fileID: st.st_ino, mountStatus: 0, linkCount: UInt32(st.st_nlink),
                    totalSize: mode == mode_t(S_IFDIR) ? 0 : st.st_size,
                    allocSize: Int64(max(0, st.st_blocks)) * 512
                ))
            }
            return results
        }

        private func finishDirectory(
            task: DirTask,
            entriesRead: Int,
            ownAllocDelta: UInt64,
            ownLogicalDelta: UInt64,
            ownHardLinkDelta: UInt64,
            keptFiles: [DiskUsageNode],
            omittedSmall: Bool,
            localIssues: Set<DiskScanIssue>,
            subdirs: [(name: String, path: String, expectedIdentity: FileIdentity?, issues: Set<DiskScanIssue>, shouldDescend: Bool, deferPhaseTwo: Bool)]
        ) {
            var progressToEmit: DiskUsageProgress?

            condition.lock()
            totalEntries += entriesRead
            totalObservedAllocated &+= ownAllocDelta
            totalObservedLogical &+= ownLogicalDelta

            dirRecords[task.recordIndex].ownAllocatedBytes &+= ownAllocDelta
            dirRecords[task.recordIndex].ownLogicalBytes &+= ownLogicalDelta
            dirRecords[task.recordIndex].ownHardLinkElsewhere &+= ownHardLinkDelta
            dirRecords[task.recordIndex].retainedFileNodes = keptFiles
            dirRecords[task.recordIndex].visited = true
            if omittedSmall {
                dirRecords[task.recordIndex].hasOmittedSmallChildren = true
            }
            dirRecords[task.recordIndex].issues.formUnion(localIssues)

            if ownAllocDelta > 0 || ownLogicalDelta > 0 {
                var ancestor = task.recordIndex
                while ancestor >= 0 {
                    dirRecords[ancestor].liveAllocatedBytes &+= ownAllocDelta
                    dirRecords[ancestor].liveLogicalBytes &+= ownLogicalDelta
                    ancestor = dirRecords[ancestor].parentIndex
                }
            }

            if task.depth == 0 {
                // Register root-level files as top branches for live Treemap updates
                for fileNode in keptFiles {
                    topBranchPaths.append(fileNode.path)
                    topBranchIsDir.append(false)
                    topBranchIsLink.append(fileNode.isSymbolicLink)
                    topBranchAllocated.append(fileNode.allocatedBytes)
                    topBranchLogical.append(fileNode.logicalBytes)
                }
            } else if task.topBranchIndex >= 0 && task.topBranchIndex < topBranchAllocated.count {
                topBranchAllocated[task.topBranchIndex] &+= ownAllocDelta
                topBranchLogical[task.topBranchIndex] &+= ownLogicalDelta
            }

            var addedTasks = false
            for sub in subdirs {
                let childIdx = dirRecords.count
                var subRecord = DirRecord(
                    path: sub.path,
                    parentIndex: task.recordIndex,
                    depth: task.depth + 1,
                    ownAllocatedBytes: 0,
                    ownLogicalBytes: 0,
                    ownHardLinkElsewhere: 0,
                    liveAllocatedBytes: 0,
                    liveLogicalBytes: 0
                )
                subRecord.issues.formUnion(sub.issues)
                dirRecords.append(subRecord)
                dirRecords[task.recordIndex].childDirIndices.append(childIdx)

                var branchIdx = task.topBranchIndex
                if task.depth == 0 {
                    branchIdx = topBranchPaths.count
                    topBranchPaths.append(sub.path)
                    topBranchIsDir.append(true)
                    topBranchIsLink.append(false)
                    topBranchAllocated.append(0)
                    topBranchLogical.append(0)
                }

                if sub.shouldDescend && !wasCancelled {
                    let next = DirTask(
                        recordIndex: childIdx,
                        path: sub.path,
                        depth: task.depth + 1,
                        expectedIdentity: sub.expectedIdentity,
                        topBranchIndex: branchIdx
                    )
                    if sub.deferPhaseTwo {
                        deferredPhaseTwo.append(next)
                    } else if next.depth <= 4 {
                        shallowQueue.append(next)
                    } else {
                        deepStack.append(next)
                    }
                    addedTasks = true
                }
            }

            if lastEmission.duration(to: .now) >= .milliseconds(250) {
                lastEmission = .now
                progressToEmit = makeLockedProgress(currentPath: task.path)
            }

            inFlight -= 1
            if addedTasks || (inFlight == 0 && (!deferredPhaseTwo.isEmpty || (shallowHead >= shallowQueue.count && deepStack.isEmpty))) {
                condition.broadcast()
            }
            condition.unlock()

            if let progressToEmit {
                onProgress(progressToEmit)
            }
        }

        private func emitProgressSnapshot(currentPath: String, force: Bool) {
            condition.lock()
            let progress: DiskUsageProgress?
            if force || lastEmission.duration(to: .now) >= .milliseconds(250) {
                lastEmission = .now
                progress = makeLockedProgress(currentPath: currentPath)
            } else {
                progress = nil
            }
            condition.unlock()
            if let progress {
                onProgress(progress)
            }
        }

        private func mountSeedDirectory(task: DirTask, seed: DiskUsageSnapshot, seedRoot: DiskUsageNode) {
            var progressToEmit: DiskUsageProgress?
            condition.lock()
            let seedCount = max(1, seed.nodes.count)
            totalEntries += seedCount
            totalObservedAllocated &+= seedRoot.allocatedBytes
            totalObservedLogical &+= seedRoot.logicalBytes

            dirRecords[task.recordIndex].ownAllocatedBytes = seedRoot.allocatedBytes
            dirRecords[task.recordIndex].ownLogicalBytes = seedRoot.logicalBytes
            dirRecords[task.recordIndex].ownHardLinkElsewhere = seedRoot.hardLinkBytesCountedElsewhere
            dirRecords[task.recordIndex].visited = true
            dirRecords[task.recordIndex].hasOmittedSmallChildren = seedRoot.hasOmittedSmallChildren
            dirRecords[task.recordIndex].issues.formUnion(seedRoot.issues)

            var ancestor = task.recordIndex
            while ancestor >= 0 {
                dirRecords[ancestor].liveAllocatedBytes &+= seedRoot.allocatedBytes
                dirRecords[ancestor].liveLogicalBytes &+= seedRoot.logicalBytes
                ancestor = dirRecords[ancestor].parentIndex
            }

            mountedSeeds.append(seed)
            mountedSeedsByPath[task.path] = seed

            if lastEmission.duration(to: .now) >= .milliseconds(250) {
                lastEmission = .now
                progressToEmit = makeLockedProgress(currentPath: task.path)
            }

            inFlight -= 1
            if inFlight == 0 && (!deferredPhaseTwo.isEmpty || (shallowHead >= shallowQueue.count && deepStack.isEmpty)) {
                condition.broadcast()
            }
            condition.unlock()

            if let progressToEmit {
                onProgress(progressToEmit)
            }
        }

        private func makeLockedProgress(currentPath: String) -> DiskUsageProgress {
            var previewNodes: [String: DiskUsageNode] = [:]
            previewNodes.reserveCapacity(512)
            let liveMaxDepth = 4

            func copyShallowSeedSubtree(from seed: DiskUsageSnapshot, path: String, remainingDepth: Int) {
                guard let node = seed.nodes[path] else { return }
                if remainingDepth <= 0 || !node.isDirectory {
                    var leaf = node
                    leaf.children = []
                    previewNodes[path] = leaf
                    return
                }
                let children = seed.children(of: path).filter { $0.allocatedBytes > 0 }.prefix(24)
                var keptChildPaths: [String] = []
                for child in children {
                    copyShallowSeedSubtree(from: seed, path: child.path, remainingDepth: remainingDepth - 1)
                    keptChildPaths.append(child.path)
                }
                var copy = node
                copy.children = keptChildPaths
                previewNodes[path] = copy
            }

            func buildLiveSubtree(recordIndex: Int) {
                let rec = dirRecords[recordIndex]
                if let seed = mountedSeedsByPath[rec.path] {
                    copyShallowSeedSubtree(from: seed, path: rec.path, remainingDepth: max(2, liveMaxDepth - rec.depth + 1))
                    return
                }
                var childPaths: [String] = []

                if rec.depth < liveMaxDepth {
                    let maxDirs = rec.depth == 0 ? 64 : 28
                    let maxFiles = rec.depth == 0 ? 48 : 16

                    var candidateDirs = rec.childDirIndices.filter { idx in
                        rec.depth == 0 || dirRecords[idx].liveAllocatedBytes > 0
                    }
                    if candidateDirs.count > maxDirs {
                        candidateDirs.sort { dirRecords[$0].liveAllocatedBytes > dirRecords[$1].liveAllocatedBytes }
                        candidateDirs = Array(candidateDirs.prefix(maxDirs))
                    }
                    for childIdx in candidateDirs {
                        buildLiveSubtree(recordIndex: childIdx)
                        childPaths.append(dirRecords[childIdx].path)
                    }

                    var candidateFiles = rec.retainedFileNodes.filter { rec.depth == 0 || $0.allocatedBytes > 0 }
                    if candidateFiles.count > maxFiles {
                        candidateFiles.sort { $0.allocatedBytes > $1.allocatedBytes }
                        candidateFiles = Array(candidateFiles.prefix(maxFiles))
                    }
                    for var fileNode in candidateFiles {
                        fileNode.issues.insert(.inProgress)
                        previewNodes[fileNode.path] = fileNode
                        childPaths.append(fileNode.path)
                    }
                }

                previewNodes[rec.path] = DiskUsageNode(
                    path: rec.path,
                    isDirectory: true,
                    isSymbolicLink: false,
                    isHardLinkDuplicate: false,
                    allocatedBytes: rec.liveAllocatedBytes,
                    logicalBytes: rec.liveLogicalBytes,
                    hardLinkBytesCountedElsewhere: 0,
                    children: childPaths,
                    issues: [.inProgress]
                )
            }

            if !dirRecords.isEmpty {
                buildLiveSubtree(recordIndex: 0)
            }

            return DiskUsageProgress(
                entries: totalEntries,
                currentPath: currentPath,
                snapshot: DiskUsageSnapshot(rootPath: rootPath, nodes: previewNodes, scannedAt: Date(), elapsed: 0)
            )
        }

        private func emitFinalProgress(from finalSnapshot: DiskUsageSnapshot) {
            guard var rootNode = finalSnapshot.root else { return }
            var previewNodes = finalSnapshot.nodes
            rootNode.issues.insert(.inProgress)
            previewNodes[rootPath] = rootNode
            onProgress(DiskUsageProgress(
                entries: totalEntries,
                currentPath: rootPath,
                snapshot: DiskUsageSnapshot(rootPath: rootPath, nodes: previewNodes, scannedAt: finalSnapshot.scannedAt, elapsed: 0)
            ))
        }

        private func buildFinalSnapshot(started: ContinuousClock.Instant) -> DiskUsageSnapshot {
            if wasCancelled || isCancelled() {
                dirRecords[0].issues.insert(.cancelled)
                for idx in 0..<dirRecords.count where !dirRecords[idx].visited {
                    dirRecords[idx].issues.insert(.cancelled)
                }
            }

            let count = dirRecords.count
            var totalAlloc = [UInt64](repeating: 0, count: count)
            var totalLogical = [UInt64](repeating: 0, count: count)
            var totalHardLink = [UInt64](repeating: 0, count: count)

            for i in 0..<count {
                totalAlloc[i] = dirRecords[i].ownAllocatedBytes
                totalLogical[i] = dirRecords[i].ownLogicalBytes
                totalHardLink[i] = dirRecords[i].ownHardLinkElsewhere
            }

            // Reverse topological pass: childIndex > parentIndex always holds.
            if count > 1 {
                for i in stride(from: count - 1, through: 1, by: -1) {
                    let parent = dirRecords[i].parentIndex
                    if parent >= 0 {
                        totalAlloc[parent] &+= totalAlloc[i]
                        totalLogical[parent] &+= totalLogical[i]
                        totalHardLink[parent] &+= totalHardLink[i]
                        if !dirRecords[i].issues.isEmpty {
                            dirRecords[parent].issues.formUnion(dirRecords[i].issues)
                        }
                    }
                }
            }

            var nodes: [String: DiskUsageNode] = [:]
            nodes.reserveCapacity(min(count * 2, 120_000))

            for i in 0..<count {
                let record = dirRecords[i]
                let keepThisDir = i == 0 ||
                    record.depth <= options.shallowFullRetentionDepth + 1 ||
                    totalAlloc[i] >= options.minRetainedChildBytesAfterShallowDepth ||
                    !record.issues.isEmpty
                guard keepThisDir else { continue }

                var childPaths: [String] = []
                childPaths.reserveCapacity(record.childDirIndices.count + record.retainedFileNodes.count)
                var omittedChildDir = record.hasOmittedSmallChildren

                for childIdx in record.childDirIndices {
                    let childRec = dirRecords[childIdx]
                    let keepChildDir = childRec.depth <= options.shallowFullRetentionDepth + 1 ||
                        totalAlloc[childIdx] >= options.minRetainedChildBytesAfterShallowDepth ||
                        !childRec.issues.isEmpty
                    if keepChildDir {
                        childPaths.append(childRec.path)
                    } else {
                        omittedChildDir = true
                    }
                }

                for fileNode in record.retainedFileNodes {
                    nodes[fileNode.path] = fileNode
                    childPaths.append(fileNode.path)
                }

                nodes[record.path] = DiskUsageNode(
                    path: record.path,
                    isDirectory: true,
                    isSymbolicLink: false,
                    isHardLinkDuplicate: false,
                    allocatedBytes: totalAlloc[i],
                    logicalBytes: totalLogical[i],
                    hardLinkBytesCountedElsewhere: totalHardLink[i],
                    children: childPaths,
                    issues: record.issues,
                    hasOmittedSmallChildren: omittedChildDir
                )
            }

            for seed in mountedSeeds {
                for (key, value) in seed.nodes {
                    nodes[key] = value
                }
            }

            let duration = started.duration(to: .now).components
            let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            return DiskUsageSnapshot(rootPath: rootPath, nodes: nodes, scannedAt: Date(), elapsed: elapsed)
        }
    }
}
