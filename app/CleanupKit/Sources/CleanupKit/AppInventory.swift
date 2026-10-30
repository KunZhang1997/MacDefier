// AppInventory — enumerate installed .app bundles for uninstall UI.
// Scan roots / protection list adapted from PureMac AppInfoFetcher (MIT).
// Size = .app bundle + related data (strict paths — no shared vendor trees).

import AppKit
import Darwin
import Foundation

public enum AppSizeState: Sendable, Hashable {
    case pending
    case measured
    case partial
    case unavailable
}

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let name: String
    public let bundleIdentifier: String
    public let path: String
    public let version: String
    /// Size of the .app package only.
    public let bytes: UInt64
    /// Related data outside the .app (support / caches / sibling game folders).
    public let relatedBytes: UInt64
    public let sizeState: AppSizeState
    public let isSystemLocation: Bool
    public let canTrashAppBundle: Bool

    public init(
        name: String,
        bundleIdentifier: String,
        path: String,
        version: String,
        bytes: UInt64,
        relatedBytes: UInt64 = 0,
        isSystemLocation: Bool,
        canTrashAppBundle: Bool,
        sizeState: AppSizeState? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.version = version
        self.bytes = bytes
        self.relatedBytes = relatedBytes
        self.sizeState = sizeState ?? ((bytes > 0 || relatedBytes > 0) ? .measured : .pending)
        self.isSystemLocation = isSystemLocation
        self.canTrashAppBundle = canTrashAppBundle
    }

    /// App package + related data (what user feels as size of the software).
    public var totalBytes: UInt64 {
        let sum = bytes.addingReportingOverflow(relatedBytes)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: totalBytes), countStyle: .file)
    }

    /// e.g. "应用 12 GB · 数据 90 GB" when related data is significant.
    public var formattedSizeDetail: String? {
        guard relatedBytes >= 50 * 1_048_576 else { return nil } // ≥ 50 MB
        let app = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
        let data = ByteCountFormatter.string(fromByteCount: Int64(clamping: relatedBytes), countStyle: .file)
        return "应用 \(app) · 数据 \(data)"
    }

    public var icon: NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}

public enum AppInventory {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let fm = FileManager.default

    /// Bundles we may show for residual cleanup, but never trash as the main app bundle.
    public static let nonRemovableBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.finder", "com.apple.AppStore",
        "com.apple.systempreferences", "com.apple.SystemSettings",
        "com.apple.Terminal", "com.apple.ActivityMonitor", "com.apple.dt.Xcode",
        "com.apple.mail", "com.apple.iCal", "com.apple.AddressBook",
        "com.apple.Preview", "com.apple.TextEdit", "com.apple.calculator",
        "com.apple.MobileSMS", "com.apple.FaceTime", "com.apple.Music",
        "com.apple.TV", "com.apple.Podcasts", "com.apple.News",
        "com.apple.Maps", "com.apple.Photos", "com.apple.Notes",
        "com.apple.reminders", "com.apple.Stocks", "com.apple.Home",
        "com.apple.weather", "com.apple.clock", "com.apple.Passwords",
        "com.macdefier.app"
    ]

    /// Executor hard gate: System tree, non-removable bids, MacDefier itself.
    public static func isProtectedAppBundle(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        if p.hasPrefix("/System") { return true }
        if p.lowercased().hasSuffix("macdefier.app") || p.localizedCaseInsensitiveContains("/MacDefier.app") {
            return true
        }
        guard p.lowercased().hasSuffix(".app") || p.contains(".app/") else { return false }
        let bundleURL: URL = {
            if p.lowercased().hasSuffix(".app") { return URL(fileURLWithPath: p) }
            // file inside bundle → walk up
            var url = URL(fileURLWithPath: p)
            while url.pathExtension != "app", url.path != "/" {
                url.deleteLastPathComponent()
            }
            return url
        }()
        guard bundleURL.pathExtension == "app", let bid = Bundle(url: bundleURL)?.bundleIdentifier else {
            return false
        }
        return nonRemovableBundleIDs.contains(bid) || bid.hasPrefix("com.macdefier.")
    }

    /// Vendor mega-folders — never fuzzy-claim the whole tree for a sub-app.
    /// 与 AppOwnership.vendorMegaFolderNames 同源（M05-1）。
    private static var blockedFuzzyFolderNames: Set<String> { AppOwnership.vendorMegaFolderNames }

    /// Generic tokens — never use alone for fuzzy matching.
    /// 与 AppOwnership.genericTokens 同源（M05-1）。
    private static var blockedFuzzyTokens: Set<String> { AppOwnership.genericTokens }

    /// Fast list: Applications folders only (depth-bounded). Size computed async optional.
    public static func fetchInstalledApps(
        includeSystemApps: Bool = false,
        computeSize: Bool = true,
        onBatch: @Sendable ([InstalledApp]) -> Void = { _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen: Set<String> = []

        var roots: [(String, Int)] = [
            ("/Applications", 6),
            ("\(home)/Applications", 6),
            ("/Users/Shared", 4)
        ]
        if includeSystemApps {
            roots.append(("/System/Applications", 6))
        }

        for (root, maxDepth) in roots {
            guard fm.fileExists(atPath: root),
                  let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  )
            else { continue }

            for case let url as URL in enumerator {
                if isCancelled() { return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
                if url.pathExtension != "app" {
                    if enumerator.level >= maxDepth {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                enumerator.skipDescendants()

                if !includeSystemApps && url.path.hasPrefix("/System") { continue }
                guard let app = loadApp(at: url, computeSize: computeSize, isCancelled: isCancelled) else { continue }
                if app.bundleIdentifier == "com.macdefier.app" { continue }
                if seen.contains(app.bundleIdentifier) { continue }
                seen.insert(app.bundleIdentifier)
                apps.append(app)
                if apps.count % 8 == 0 { onBatch(apps) }
            }
        }

        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func loadApp(
        at url: URL,
        computeSize: Bool = true,
        sizeTimeLimit: TimeInterval = 8,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> InstalledApp? {
        loadApp(at: url, computeSize: computeSize, sizeTimeLimit: sizeTimeLimit,
                sizeEnvironment: .init(home: home, sharedRoot: "/Users/Shared"), isCancelled: isCancelled)
    }

    /// Internal fixture environment: tests never enumerate the real user's data.
    struct SizeEnvironment {
        let home: String
        let sharedRoot: String
        var nodeLimit: Int = 400_000
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    static func loadApp(
        at url: URL,
        computeSize: Bool = true,
        sizeTimeLimit: TimeInterval = 8,
        sizeEnvironment: SizeEnvironment,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> InstalledApp? {
        guard url.pathExtension == "app" else { return nil }
        guard let bundle = Bundle(url: url) else { return nil }
        let bundleID = bundle.bundleIdentifier
            ?? url.deletingPathExtension().lastPathComponent
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "—"
        var appBytes: UInt64 = 0
        var related: UInt64 = 0
        var sizeState: AppSizeState = .pending
        if computeSize {
            let budget = SizeBudget(timeLimit: sizeTimeLimit, environment: sizeEnvironment)
            appBytes = directorySize(url.path, budget: budget, isCancelled: isCancelled)
            let paths = relatedDataPaths(name: name, bundleID: bundleID, appPath: url.path,
                                         environment: sizeEnvironment, budget: budget, isCancelled: isCancelled)
            for path in paths {
                guard budget.canContinue(isCancelled) else { break }
                related = budget.add(related, directorySize(path, budget: budget, isCancelled: isCancelled))
            }
            sizeState = budget.incomplete ? (budget.hasMeasurement ? .partial : .unavailable) : .measured
        }
        let isSystemLocation = url.path.hasPrefix("/System")
        return InstalledApp(
            name: name,
            bundleIdentifier: bundleID,
            path: url.path,
            version: version,
            bytes: appBytes,
            relatedBytes: related,
            isSystemLocation: isSystemLocation,
            canTrashAppBundle: !isSystemLocation && !nonRemovableBundleIDs.contains(bundleID) && !bundleID.hasPrefix("com.macdefier."),
            sizeState: sizeState
        )
    }

    // MARK: - Related data (strict)

    private static func relatedDataPaths(
        name: String,
        bundleID: String,
        appPath: String,
        environment: SizeEnvironment,
        budget: SizeBudget,
        isCancelled: @Sendable () -> Bool
    ) -> [String] {
        // Chrome Apps (Telegram Web etc.): shell only — do not attach Chrome profile data
        if appPath.contains("Chrome Apps") || bundleID.contains("com.google.Chrome.app.") {
            return []
        }

        var paths: [String] = []
        var seen = Set<String>()
        let baseName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        let home = environment.home

        func add(_ p: String) {
            let n = (p as NSString).standardizingPath
            guard n != appPath, !n.hasPrefix(appPath + "/"), !appPath.hasPrefix(n + "/") else { return }
            guard seen.insert(n).inserted else { return }
            guard budget.consume(isCancelled) else { return }
            do {
                let parent = try openSizeDirectory((n as NSString).deletingLastPathComponent, budget: budget, isCancelled: isCancelled)
                defer { close(parent) }
                var info = stat()
                guard fstatat(parent, (n as NSString).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno != ENOENT { budget.incomplete = true }
                    return
                }
                guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { return }
            } catch { budget.noteOptionalRootFailure(error) ; return }
            paths.append(n)
        }

        // Exact: bundle id / exact display name (鸣潮 Container etc.)
        add("\(home)/Library/Application Support/\(bundleID)")
        add("\(home)/Library/Application Support/\(name)")
        add("\(home)/Library/Application Support/\(baseName)")
        add("\(home)/Library/Caches/\(bundleID)")
        add("\(home)/Library/Caches/\(name)")
        add("\(home)/Library/Containers/\(bundleID)")
        add("\(home)/Library/Group Containers/\(bundleID)")

        // Chrome / Drive：与 ResidualMatcher 共用 AppOwnership 通道表
        for p in AppOwnership.channelRelatedPaths(bundleID: bundleID, appPath: appPath, home: home) {
            add(p)
        }

        // Sibling game folders next to .app
        let parent = URL(fileURLWithPath: appPath).deletingLastPathComponent().path
        let siblingSuffixes = [
            " Game", "Game", " Data", "Data", " Client", "Client",
            " Game Data", "GameData", "_Data", " Resources", "Resources"
        ]
        for suffix in siblingSuffixes {
            add("\(parent)/\(baseName)\(suffix)")
            if name != baseName { add("\(parent)/\(name)\(suffix)") }
        }

        // Tight fuzzy: equal strong token / full name — not "contains google"
        let tokens = matchTokens(name: name, baseName: baseName, bundleID: bundleID)
        let supportRoot = "\(home)/Library/Application Support"
        for entry in directoryNames(supportRoot, limit: 800, budget: budget, isCancelled: isCancelled) {
            if entry.hasPrefix(".") { continue }
            guard fuzzyFolderAllowed(entry: entry, tokens: tokens, name: name, baseName: baseName) else {
                continue
            }
            add((supportRoot as NSString).appendingPathComponent(entry))
        }
        for root in ["\(home)/Games", environment.sharedRoot] {
            for entry in directoryNames(root, limit: 200, budget: budget, isCancelled: isCancelled) {
                guard fuzzyFolderAllowed(entry: entry, tokens: tokens, name: name, baseName: baseName) else {
                    continue
                }
                add((root as NSString).appendingPathComponent(entry))
            }
        }

        // Parents win over descendants, independent of discovery order. This
        // prevents channel roots and exact/fuzzy matches counting a tree twice.
        var roots: [String] = []
        for path in paths.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            if !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { roots.append(path) }
        }
        return roots
    }

    private static func fuzzyFolderAllowed(
        entry: String,
        tokens: [String],
        name: String,
        baseName: String
    ) -> Bool {
        let lower = entry.lowercased()
        if blockedFuzzyFolderNames.contains(lower) { return false }
        if lower == name.lowercased() || lower == baseName.lowercased() { return true }
        for t in tokens {
            if lower == t { return true }
            if lower.hasPrefix(t + " ") || lower.hasPrefix(t + "-") || lower.hasPrefix(t + "_") {
                return true
            }
        }
        return false
    }

    private static func matchTokens(name: String, baseName: String, bundleID: String) -> [String] {
        var tokens: [String] = []
        func push(_ s: String) {
            let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if blockedFuzzyTokens.contains(t) { return }
            let hasCJK = t.unicodeScalars.contains {
                ($0.value >= 0x4E00 && $0.value <= 0x9FFF)
                    || ($0.value >= 0x3400 && $0.value <= 0x4DBF)
            }
            if hasCJK {
                guard t.count >= 2 else { return }
            } else {
                guard t.count >= 5 else { return }
            }
            if !tokens.contains(t) { tokens.append(t) }
        }
        push(name)
        push(baseName)
        for part in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            push(String(part))
        }
        let parts = bundleID.split(separator: ".").map(String.init)
        if let last = parts.last { push(last) }
        if parts.count >= 2 { push(parts[parts.count - 2]) }
        return tokens
    }

    // MARK: - Size

    private struct SizeFileID: Hashable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }

    private enum SizeReadFailure: Error { case stopped, system(Int32) }

    /// One cooperative budget covers package traversal, related-path discovery
    /// and every related tree. No file contents are opened for size measurement.
    private final class SizeBudget {
        let deadline: TimeInterval
        let nodeLimit: Int
        let now: () -> TimeInterval
        var nodes = 0
        var incomplete = false
        var stopped = false
        var hasMeasurement = false
        var visitedDirectories: Set<SizeFileID> = []
        var visitedFiles: Set<SizeFileID> = []

        init(timeLimit: TimeInterval, environment: SizeEnvironment) {
            now = environment.now
            deadline = environment.now() + min(8, max(0, timeLimit.isFinite ? timeLimit : 0))
            nodeLimit = min(400_000, max(0, environment.nodeLimit))
        }

        func canContinue(_ isCancelled: () -> Bool) -> Bool {
            guard !stopped else { return false }
            if isCancelled() || Task.isCancelled || now() >= deadline || nodes >= nodeLimit {
                incomplete = true
                stopped = true
                return false
            }
            return true
        }

        func consume(_ isCancelled: () -> Bool) -> Bool {
            guard canContinue(isCancelled) else { return false }
            nodes += 1
            return true
        }

        func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let sum = lhs.addingReportingOverflow(rhs)
            if sum.overflow { incomplete = true }
            return sum.overflow ? UInt64.max : sum.partialValue
        }

        func allocatedBytes(_ info: stat) -> UInt64 {
            hasMeasurement = true
            guard visitedFiles.insert(SizeFileID(info)).inserted else { return 0 }
            guard info.st_blocks >= 0 else { incomplete = true; return 0 }
            let bytes = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
            if bytes.overflow { incomplete = true }
            return bytes.overflow ? UInt64.max : bytes.partialValue
        }

        func noteOptionalRootFailure(_ error: Error) {
            // Missing candidates are normal. A symlink component is deliberately
            // excluded, not followed into another tree. Other failures are visible.
            if case SizeReadFailure.system(let code) = error, [ENOENT, ENOTDIR, ELOOP].contains(code) { return }
            incomplete = true
        }
    }

    private static func openSizeDirectory(_ path: String, budget: SizeBudget,
                                          isCancelled: @Sendable () -> Bool) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains("..") else { throw SizeReadFailure.system(EINVAL) }
        guard budget.canContinue(isCancelled) else { throw SizeReadFailure.stopped }
        // Fixed platform aliases only; user-controlled symlink ancestors stay excluded.
        var traversal = path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            traversal = "/private" + path
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SizeReadFailure.system(errno) }
        for part in traversal.split(separator: "/") {
            guard budget.canContinue(isCancelled) else { close(fd); throw SizeReadFailure.stopped }
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = errno
            close(fd)
            guard next >= 0 else { throw SizeReadFailure.system(error) }
            fd = next
        }
        return fd
    }

    private static func directoryNames(_ path: String, limit: Int, budget: SizeBudget,
                                       isCancelled: @Sendable () -> Bool) -> [String] {
        guard budget.canContinue(isCancelled) else { return [] }
        let fd: Int32
        do { fd = try openSizeDirectory(path, budget: budget, isCancelled: isCancelled) }
        catch { budget.noteOptionalRootFailure(error); return [] }
        guard let directory = fdopendir(fd) else { close(fd); budget.incomplete = true; return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while budget.canContinue(isCancelled) {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { budget.incomplete = true }
                break
            }
            let name = directoryEntryName(entry)
            if name == "." || name == ".." { continue }
            guard budget.consume(isCancelled) else { break }
            guard names.count < limit else { budget.incomplete = true; break }
            names.append(name)
        }
        return names
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
        }
    }

    private static func directorySize(_ path: String, budget: SizeBudget,
                                      isCancelled: @Sendable () -> Bool) -> UInt64 {
        guard budget.consume(isCancelled) else { return 0 }
        let parent: Int32
        do { parent = try openSizeDirectory((path as NSString).deletingLastPathComponent, budget: budget, isCancelled: isCancelled) }
        catch { budget.incomplete = true; return 0 }
        defer { close(parent) }
        let name = (path as NSString).lastPathComponent
        var root = stat()
        guard fstatat(parent, name, &root, AT_SYMLINK_NOFOLLOW) == 0 else { budget.incomplete = true; return 0 }
        let rootKind = root.st_mode & mode_t(S_IFMT)
        if rootKind == mode_t(S_IFREG) { return budget.allocatedBytes(root) }
        guard rootKind == mode_t(S_IFDIR) else { budget.incomplete = true; return 0 }

        // Iterative descriptor-bound traversal avoids both recursive stack growth
        // and following a directory replaced with a symlink after its stat.
        var stack: [UnsafeMutablePointer<DIR>] = []
        defer { for directory in stack { closedir(directory) } }
        func enter(_ parentFD: Int32, _ leaf: String, expected: stat) {
            guard budget.canContinue(isCancelled), !budget.visitedDirectories.contains(SizeFileID(expected)) else { return }
            let fd = openat(parentFD, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { budget.incomplete = true; return }
            var fresh = stat()
            guard fstat(fd, &fresh) == 0, SizeFileID(fresh) == SizeFileID(expected) else {
                close(fd); budget.incomplete = true; return
            }
            guard let directory = fdopendir(fd) else { close(fd); budget.incomplete = true; return }
            budget.visitedDirectories.insert(SizeFileID(fresh))
            stack.append(directory)
        }
        enter(parent, name, expected: root)
        var total: UInt64 = 0
        while let directory = stack.last, budget.canContinue(isCancelled) {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno == 0 { budget.hasMeasurement = true } else { budget.incomplete = true }
                closedir(directory)
                stack.removeLast()
                continue
            }
            let child = directoryEntryName(entry)
            if child == "." || child == ".." { continue }
            guard budget.consume(isCancelled) else { break }
            var info = stat()
            guard fstatat(dirfd(directory), child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { budget.incomplete = true; continue }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG): total = budget.add(total, budget.allocatedBytes(info))
            case mode_t(S_IFDIR): enter(dirfd(directory), child, expected: info)
            default: break // Symlinks and special files are never followed/opened.
            }
        }
        return total
    }
}
