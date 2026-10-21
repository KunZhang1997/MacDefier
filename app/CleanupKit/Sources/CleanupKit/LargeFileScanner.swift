// Large-item discovery shares the bounded, metadata-only disk accounting engine.
import Foundation

public struct LargeFileScanResult: Sendable {
    public let items: [CleanableItem]
    public let isPartial: Bool
}

public enum LargeFileScanner {
    private static let fm = FileManager.default
    private static var home: String { fm.homeDirectoryForCurrentUser.path }
    public static let minBytes: UInt64 = 100 * 1024 * 1024
    public static let maxItems = 50

    public static func scan() async -> [CleanableItem] { await scanReport().items }

    public static func scanReport() async -> LargeFileScanResult {
        let roots = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures",
                     "Library/Application Support", ".ollama", ".lmstudio", ".cache", ".local/share"]
        var candidates: [String: DiskUsageNode] = [:]
        var partial = false
        for relative in roots {
            if Task.isCancelled { partial = true; break }
            let root = URL(fileURLWithPath: home).appendingPathComponent(relative)
            guard fm.fileExists(atPath: root.path) else { continue }
            let worker = Task.detached(priority: .utility) {
                DiskUsageScanner.scan(root: root,
                    budget: DiskScanBudget(maxEntries: 15_000, maxSeconds: 1.5),
                    isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await worker.value }
                onCancel: { worker.cancel() }
            partial = partial || result.root?.isComplete != true
            let children = result.children(of: result.rootPath)
            var nodes = children
            // Model roots themselves can be large; scan roots otherwise stay out of the list.
            if relative == ".ollama" || relative == ".lmstudio", let rootNode = result.root { nodes.append(rootNode) }
            for child in children where child.isDirectory {
                nodes += result.children(of: child.path).filter { !$0.isDirectory }
            }
            for node in nodes where node.allocatedBytes >= minBytes && !node.isSymbolicLink {
                let path = PathGate.normalize(node.path)
                guard !ProtectedMediaRoots.contains(path), !shouldSkip(path), !isScanRoot(path) else { continue }
                candidates[path] = node
            }
        }
        // Keep child detail instead of a nearly identical parent total.
        for path in Array(candidates.keys) {
            guard let parent = candidates[path], parent.isDirectory else { continue }
            let largestChild = candidates.filter { $0.key.hasPrefix(path + "/") }.map { $0.value.allocatedBytes }.max() ?? 0
            if Double(largestChild) >= Double(parent.allocatedBytes) * 0.7 { candidates.removeValue(forKey: path) }
        }
        let sorted = candidates.sorted {
            $0.value.allocatedBytes == $1.value.allocatedBytes ? $0.key < $1.key : $0.value.allocatedBytes > $1.value.allocatedBytes
        }
        if sorted.count > maxItems { partial = true }
        let items = sorted.prefix(maxItems).compactMap { path, node in
            makeItem(path: path, bytes: node.allocatedBytes, isDir: node.isDirectory, isPartial: !node.isComplete)
        }
        return LargeFileScanResult(items: items, isPartial: partial)
    }

    // MARK: - filters / items

    private static func isScanRoot(_ path: String) -> Bool {
        let roots = [
            "\(home)/Downloads", "\(home)/Desktop", "\(home)/Documents",
            "\(home)/Movies", "\(home)/Music", "\(home)/Pictures",
            "\(home)/Library/Application Support", "\(home)/.cache", "\(home)/.local/share",
        ].map { PathGate.normalize($0) }
        return roots.contains(PathGate.normalize(path))
    }

    private static func shouldSkip(_ path: String) -> Bool {
        // All installer artifacts belong to InstallerPackageScanner, regardless of size.
        if InstallerPackageScanner.isInstallerPackagePath(path) { return true }
        let p = path.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name == "node_modules" || name == ".git" { return true }
        if p.contains("/library/caches/") || p.contains("/library/logs/") { return true }
        if p.contains("mobile documents") || p.contains("clouddocs") { return true }
        // Photos library: show is OK but trash blocked; still skip deep noise
        if name.hasSuffix(".photoslibrary") { return true }
        // inventory-only 根（.colima、SpeakSend 等）不进大文件可清理列表
        if AppDataLocations.isUnderAllowedRoot(path) { return true }
        // 不允许直接清理的 Application Support 根本身
        let asRoot = PathGate.standardizeOnly(home + "/Library/Application Support")
        let n = PathGate.normalize(path)
        if n == asRoot { return true }
        return false
    }

    private static func makeItem(path: String, bytes: UInt64, isDir: Bool, isPartial: Bool) -> CleanableItem? {
        guard fm.fileExists(atPath: path) else { return nil }
        // 扫描产出必须能通过同一执行 PathGate
        guard PathGate.isSafeToTrash(path) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let kind = isDir ? "文件夹" : "文件"
        let rel: String = {
            if path.hasPrefix(home + "/") { return String(path.dropFirst(home.count + 1)) }
            return path
        }()
        return CleanableItem(
            name: name,
            path: path,
            bytes: bytes,
            category: .largeAppData,
            isSelected: false,
            appName: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
            displayTitle: "\(name) · \(kind)",
            whatIsIt: "按体积发现的大\(kind)（≥约 100MB）。\(rel)",
            ifCleaned: "进废纸篓可还原。可能是个人文件/项目，默认不勾。",
            risk: .caution,
            parentPath: (path as NSString).deletingLastPathComponent,
            sizeIsLowerBound: isPartial
        )
    }
}
