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
    public var isComplete: Bool { issues.isEmpty }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

public struct DiskUsageSnapshot: Sendable {
    public let rootPath: String
    public let nodes: [String: DiskUsageNode]
    public let scannedAt: Date
    public let elapsed: TimeInterval
    public var root: DiskUsageNode? { nodes[rootPath] }

    public func children(of path: String) -> [DiskUsageNode] {
        (nodes[path]?.children ?? []).compactMap { nodes[$0] }.sorted {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path < $1.path
        }
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
                let childPath = URL(fileURLWithPath: path).appendingPathComponent(name).path
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

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}
