// AppInventory — enumerate installed .app bundles for uninstall UI.
// Scan roots / protection list adapted from PureMac AppInfoFetcher (MIT).
// Size = .app bundle + related data (strict paths — no shared vendor trees).

import AppKit
import Foundation

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
        canTrashAppBundle: Bool
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.version = version
        self.bytes = bytes
        self.relatedBytes = relatedBytes
        self.isSystemLocation = isSystemLocation
        self.canTrashAppBundle = canTrashAppBundle
    }

    /// App package + related data (what user feels as size of the software).
    public var totalBytes: UInt64 { bytes &+ relatedBytes }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }

    /// e.g. "应用 12 GB · 数据 90 GB" when related data is significant.
    public var formattedSizeDetail: String? {
        guard relatedBytes >= 50 * 1_048_576 else { return nil } // ≥ 50 MB
        let app = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let data = ByteCountFormatter.string(fromByteCount: Int64(relatedBytes), countStyle: .file)
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
        let appBytes: UInt64 = computeSize ? directorySize(url.path, isCancelled: isCancelled) : 0
        let related: UInt64 = computeSize
            ? relatedDataBytes(name: name, bundleID: bundleID, appPath: url.path, isCancelled: isCancelled)
            : 0
        let isSystemLocation = url.path.hasPrefix("/System")
        return InstalledApp(
            name: name,
            bundleIdentifier: bundleID,
            path: url.path,
            version: version,
            bytes: appBytes,
            relatedBytes: related,
            isSystemLocation: isSystemLocation,
            canTrashAppBundle: !isSystemLocation && !nonRemovableBundleIDs.contains(bundleID) && !bundleID.hasPrefix("com.macdefier.")
        )
    }

    // MARK: - Related data (strict)

    private static func relatedDataBytes(
        name: String,
        bundleID: String,
        appPath: String,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> UInt64 {
        // Chrome Apps (Telegram Web etc.): shell only — do not attach Chrome profile data
        if appPath.contains("Chrome Apps") || bundleID.contains("com.google.Chrome.app.") {
            return 0
        }

        var paths: [String] = []
        var seen = Set<String>()
        let baseName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent

        func add(_ p: String) {
            let n = (p as NSString).standardizingPath
            guard n != appPath, !n.hasPrefix(appPath + "/") else { return }
            guard seen.insert(n).inserted else { return }
            guard fm.fileExists(atPath: n) else { return }
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
        if let names = try? fm.contentsOfDirectory(atPath: supportRoot) {
            for entry in names.prefix(800) {
                if entry.hasPrefix(".") { continue }
                guard fuzzyFolderAllowed(entry: entry, tokens: tokens, name: name, baseName: baseName) else {
                    continue
                }
                add((supportRoot as NSString).appendingPathComponent(entry))
            }
        }
        for root in ["\(home)/Games", "/Users/Shared"] {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in names.prefix(200) {
                guard fuzzyFolderAllowed(entry: entry, tokens: tokens, name: name, baseName: baseName) else {
                    continue
                }
                add((root as NSString).appendingPathComponent(entry))
            }
        }

        var total: UInt64 = 0
        for p in paths {
            if isCancelled() { return total }
            total &+= directorySize(p, isCancelled: isCancelled)
        }
        return total
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

    private static func directorySize(
        _ path: String,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
            return UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
        }

        var total: UInt64 = 0
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ],
            options: []
        ) else { return 0 }

        var n = 0
        let hardCap = 400_000
        for case let file as URL in en {
            if isCancelled() { break }
            n += 1
            if n > hardCap { break }
            guard let vals = try? file.resourceValues(forKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ]) else { continue }
            guard vals.isRegularFile == true else { continue }
            let size = vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? vals.fileSize ?? 0
            total &+= UInt64(size)
        }
        return total
    }
}
