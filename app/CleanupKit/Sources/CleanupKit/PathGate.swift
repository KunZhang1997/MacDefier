// PathGate — single source for scan / trash / uninstall path policy.
// Three gates share hardBlock + normalize; trash must NOT early-true AppDataLocations
// (inventory roots ≠ deletable). Uninstall .app only when path == allowAppBundle.

import Foundation

/// Unified path safety for CleanupKit. Prefer these over private copies in executors.
public enum PathGate {
    private static var fm: FileManager { .default }
    private static var home: String { fm.homeDirectoryForCurrentUser.path }

    // MARK: - Normalize

    /// 尽可能解析中间符号链接（leaf 不存在时 Foundation 的 resolvingSymlinksInPath 会原样返回）。
    public static func normalize(_ path: String) -> String {
        let standardized = standardizeOnly(path)
        let full = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().standardizedFileURL.path
        if full != standardized || fm.fileExists(atPath: standardized) {
            return full
        }
        // 逐组件解析：allow 根是 symlink 且 leaf 尚不存在时也能落到真实目录
        var accumulated = ""
        let parts = (standardized as NSString).pathComponents
        for (idx, part) in parts.enumerated() {
            if idx == 0, part == "/" {
                accumulated = "/"
                continue
            }
            if accumulated == "/" {
                accumulated = "/" + part
            } else if accumulated.isEmpty {
                accumulated = part
            } else {
                accumulated = (accumulated as NSString).appendingPathComponent(part)
            }
            if let dest = try? fm.destinationOfSymbolicLink(atPath: accumulated) {
                if dest.hasPrefix("/") {
                    accumulated = standardizeOnly(dest)
                } else {
                    let parent = (accumulated as NSString).deletingLastPathComponent
                    accumulated = standardizeOnly((parent as NSString).appendingPathComponent(dest))
                }
            }
        }
        return URL(fileURLWithPath: accumulated).standardizedFileURL.path
    }

    // MARK: - Shared hard blocks (sensitive user / system)

    /// 密钥/凭证/系统树：任何 allow 之前必须硬拒（含 symlink 落入）。
    /// 不含 Documents/Downloads 等个人目录（大文件清理需要例外）。
    public static func secretHardBlockPrefixes(home homePath: String? = nil) -> [String] {
        let h = homePath ?? home
        return [
            h + "/Library/Keychains",
            h + "/Library/Mail",
            h + "/Library/Messages",
            h + "/Library/Mobile Documents",
            h + "/.ssh",
            h + "/.aws",
            h + "/.gnupg",
            "/System",
            "/usr/bin",
            "/usr/sbin",
            "/bin",
            "/sbin"
        ]
    }

    /// 个人数据根 + Preferences：扫描默认不进；清理除大文件闸外不整树删除。
    public static func personalDataHardBlockPrefixes(home homePath: String? = nil) -> [String] {
        let h = homePath ?? home
        return [
            h + "/Documents",
            h + "/Desktop",
            h + "/Downloads",
            h + "/Pictures",
            h + "/Library/Preferences"
        ]
    }

    /// Paths that must never appear in junk scan / cleanup trash (resolved).
    /// Uninstall uses `uninstallHardBlockPrefixes` (Preferences 可卸单文件 plist，不在此整树拦).
    public static func sensitiveHardBlockPrefixes(home homePath: String? = nil) -> [String] {
        secretHardBlockPrefixes(home: homePath) + personalDataHardBlockPrefixes(home: homePath)
    }

    /// Uninstall residual hard blocks (no whole Preferences tree — plists gated separately).
    public static func uninstallHardBlockPrefixes(home homePath: String? = nil) -> [String] {
        let h = homePath ?? home
        return secretHardBlockPrefixes(home: h) + [
            h + "/Documents",
            h + "/Desktop",
            h + "/Downloads",
            h + "/Pictures"
        ]
    }

    /// 密钥硬闸：原始标准化路径与解析后路径任一命中即拒。
    public static func isSecretHardBlocked(_ path: String, home homePath: String? = nil) -> Bool {
        let h = homePath ?? home
        let prefixes = secretHardBlockPrefixes(home: h)
        if isUnderComponentPrefixes(standardizeOnly(path), prefixes) { return true }
        if isUnderComponentPrefixes(normalize(path), prefixes) { return true }
        return false
    }

    public static func isSensitiveHardBlocked(_ path: String, home homePath: String? = nil) -> Bool {
        let h = homePath ?? home
        let prefixes = sensitiveHardBlockPrefixes(home: h)
        if isUnderComponentPrefixes(standardizeOnly(path), prefixes) { return true }
        if isUnderComponentPrefixes(normalize(path), prefixes) { return true }
        return false
    }

    public static func isUninstallHardBlocked(_ path: String, home homePath: String? = nil) -> Bool {
        let h = homePath ?? home
        let prefixes = uninstallHardBlockPrefixes(home: h)
        if isUnderComponentPrefixes(standardizeOnly(path), prefixes) { return true }
        if isUnderComponentPrefixes(normalize(path), prefixes) { return true }
        return false
    }

    /// 不解析符号链接，仅 standardize（用于 hard-block 原始路径）
    public static func standardizeOnly(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// 组件边界前缀匹配（`/foo` 不匹配 `/foobar`）
    /// 注意：不得无条件兜底整棵 `/usr`——否则会毒化 `junkAllowPrefixes` 中的
    /// `/usr/local/Homebrew/Library/Caches`；`/usr/bin`、`/usr/sbin` 已在 secret 表中硬拒。
    public static func isUnderComponentPrefixes(_ path: String, _ prefixes: [String]) -> Bool {
        let lower = path.lowercased()
        for b in prefixes {
            let bl = standardizeOnly(b).lowercased()
            if lower == bl || lower.hasPrefix(bl + "/") { return true }
        }
        return false
    }

    private static func isUnderAnyPrefix(_ path: String, _ prefixes: [String]) -> Bool {
        // 历史名：解析后组件边界匹配
        isUnderComponentPrefixes(normalize(path), prefixes.map { standardizeOnly($0) })
    }

    // MARK: - Scan gate

    /// Can this path appear in junk scan results?
    public static func isPathAllowedForScan(_ path: String, home homePath: String? = nil) -> Bool {
        let h = homePath ?? home
        let resolved = normalize(path)

        // 密钥/敏感：解析前后任一命中 → 永不进扫描（含 symlink 绕过）
        if isSensitiveHardBlocked(path, home: h) { return false }
        if isBrowserCredentialPath(resolved) { return false }

        // Docker / AI / browser carve-outs（仅在 hard-block 之后；allow 根不得落入密钥）
        if underAllowedPrefix(path, dockerAllowPrefixes(home: h), home: h) { return true }
        if underAllowedPrefix(path, aiAllowPrefixes(home: h), home: h) { return true }
        if underAllowedPrefix(path, BrowserCleanupCatalog.allowedPathPrefixes(home: h), home: h) {
            return true
        }

        // Hard blocks including Containers / Group Containers / Applications
        let scanHard = sensitiveHardBlockPrefixes(home: h) + [
            h + "/Library/Containers",
            h + "/Library/Group Containers",
            h + "/Library/Application Scripts",
            "/Applications"
        ]
        if isUnderComponentPrefixes(resolved, scanHard) { return false }
        if isUnderComponentPrefixes(standardizeOnly(path), scanHard) { return false }

        return underAllowedPrefix(path, junkAllowPrefixes(home: h), home: h)
    }

    // MARK: - Trash gate

    /// Can Cleanup trashItem / removeItem this path?
    /// - Parameter home: 可注入测试 home，避免改真实用户目录
    public static func isSafeToTrash(_ path: String, home homePath: String? = nil) -> Bool {
        let h = homePath ?? home
        let resolved = normalize(path)
        let lower = resolved.lowercased()

        if ProtectedMediaRoots.contains(resolved) { return false }
        if ProtectedMediaRoots.contains(standardizeOnly(path)) { return false }

        // Exact never-delete roots (folder roots themselves)
        let never = [
            "/", "/system", "/users", h,
            h + "/library",
            h + "/documents",
            h + "/desktop",
            h + "/downloads",
            h + "/pictures",
            h + "/movies",
            h + "/music",
            "/library",
            "/applications"
        ]
        for n in never {
            if lower == n.lowercased() { return false }
            if standardizeOnly(path).lowercased() == n.lowercased() { return false }
        }

        // 密钥硬闸优先于任何 allow（M03-1）— 不含 Downloads 等个人根（大文件闸需要）
        if isSecretHardBlocked(path, home: h) { return false }
        if isBrowserCredentialPath(resolved) || isBrowserCredentialPath(path) { return false }

        // Docker / AI / CLI / browser carve-outs：allow 命中后仍不得绕过 sensitive hard-block
        // （allow 根或中途 symlink → Documents/Preferences/密钥 等）
        if underAllowedPrefix(path, dockerAllowPrefixes(home: h), home: h) {
            return !isSensitiveHardBlocked(path, home: h)
        }
        if underAllowedPrefix(path, aiAllowPrefixes(home: h), home: h) {
            return !isSensitiveHardBlocked(path, home: h)
        }
        if underAllowedPrefix(path, cliDataAllowPrefixes(home: h), home: h) {
            return !isSensitiveHardBlocked(path, home: h)
        }
        if underAllowedPrefix(path, BrowserCleanupCatalog.allowedPathPrefixes(home: h), home: h) {
            return !isSensitiveHardBlocked(path, home: h)
        }

        // macOS Aerials: only the dedicated policy may open this otherwise
        // inventory-only root, and it re-reads the active wallpaper state.
        if WallpaperCleanupPolicy.isManagedResourcePath(path, home: h) {
            return WallpaperCleanupPolicy.isSafeToTrash(path, home: h)
        }

        // Dedicated installer category: exact DMG/PKG/MPKG items under user-facing
        // roots are trashable even below the large-file threshold. This narrow gate
        // does not make the parent roots generally deletable.
        if isSafeInstallerPackageTrashPath(path, home: h) { return true }

        // C09 large-file（个人目录大文件例外；内部仍拒密钥与 inventory-only）
        if isAllowedLargeFileTrashPath(path, home: h) { return true }

        // User LaunchAgents: single plist only
        let laRoot = standardizeOnly(h + "/Library/LaunchAgents")
        let stdPath = standardizeOnly(path)
        if (resolved.hasPrefix(laRoot + "/") || stdPath.hasPrefix(laRoot + "/")),
           (resolved.hasSuffix(".plist") || stdPath.hasSuffix(".plist")) {
            return !isSecretHardBlocked(path, home: h)
        }

        for shimRoot in [standardizeOnly(h + "/.local/bin"), standardizeOnly(h + "/bin")] {
            for candidate in [resolved, stdPath] where candidate.hasPrefix(shimRoot + "/") {
                let rest = String(candidate.dropFirst(shimRoot.count + 1))
                if !rest.isEmpty, !rest.contains("/") {
                    return !isSecretHardBlocked(path, home: h)
                }
            }
        }

        // 通用 junk allow：同样不得绕过 sensitive hard-block（Caches→Documents symlink）
        return underAllowedPrefix(path, trashAllowPrefixes(home: h), home: h)
            && !isSensitiveHardBlocked(path, home: h)
    }

    /// A container is not generic junk. Only the orphan workflow may grant an
    /// exact, direct-child container after re-reading ownership evidence.
    public static func isSafeOrphanToTrash(
        _ path: String,
        installedApps: [InstalledApp]?,
        home homePath: String? = nil
    ) -> Bool {
        let h = homePath ?? home
        let raw = standardizeOnly(path)
        let resolved = normalize(path)
        let containerRoot = standardizeOnly(h + "/Library/Containers")
        let groupRoot = standardizeOnly(h + "/Library/Group Containers")
        let isContainer = [containerRoot, groupRoot].contains { root in
            [raw, resolved].contains { $0 == root || $0.hasPrefix(root + "/") }
        }
        guard isContainer else { return isSafeToTrash(path, home: h) }
        guard raw == resolved,
              URL(fileURLWithPath: raw).deletingLastPathComponent().path == containerRoot,
              !isSensitiveHardBlocked(path, home: h),
              !ProtectedMediaRoots.contains(resolved),
              let installedApps, !installedApps.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: raw, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return ContainerOwnershipScanner.inspect(
            path: raw, isGroupContainer: false, installed: installedApps
        ).confidence == .verifiedOrphan
    }

    /// Narrow gate for the installer-package category.
    /// Only exact `.dmg`, `.pkg`, `.mpkg` items under user-facing roots are granted.
    public static func isSafeInstallerPackageTrashPath(
        _ path: String,
        home homePath: String? = nil,
        sharedRoot: String? = "/Users/Shared"
    ) -> Bool {
        let h = homePath ?? home
        let std = standardizeOnly(path)
        let resolved = normalize(path)
        guard std == resolved else { return false }
        guard InstallerPackageScanner.isInstallerPackagePath(resolved) else { return false }
        guard !isSecretHardBlocked(path, home: h) else { return false }
        guard !ProtectedMediaRoots.contains(resolved) else { return false }
        guard fm.fileExists(atPath: resolved) else { return false }
        if (try? URL(fileURLWithPath: std).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }

        var roots = [
            standardizeOnly(h + "/Downloads"),
            standardizeOnly(h + "/Desktop"),
            standardizeOnly(h + "/Documents")
        ]
        if let sharedRoot { roots.append(standardizeOnly(sharedRoot)) }
        return roots.contains { root in
            resolved.hasPrefix(root + "/")
        }
    }

    /// C09: trash only large (≥ minBytes) children under personal / shallow AS / cache homes.
    /// - Never folder roots themselves
    /// - Never AppData inventory roots (SpeakSend / MuMu / colima / photos…)
    /// - Never Containers tree (docker carve-out already handled above)
    /// - AS: only **direct** children (depth-1), not arbitrary nested paths
    /// - Never secrets (even if huge under a personal path via symlink)
    public static func isAllowedLargeFileTrashPath(_ path: String, home homePath: String? = nil) -> Bool {
        let h = homePath ?? home
        let resolved = normalize(path)
        let std = standardizeOnly(path)
        if ProtectedMediaRoots.contains(resolved) || ProtectedMediaRoots.contains(std) { return false }
        if isSecretHardBlocked(path, home: h) { return false }
        // Inventory-only trees stay non-deletable via cleanup (even if huge)
        if AppDataLocations.isUnderAllowedRoot(resolved) || AppDataLocations.isUnderAllowedRoot(std) {
            return false
        }
        // Containers: not via large-file gate
        let containers = standardizeOnly(h + "/Library/Containers")
        let groupC = standardizeOnly(h + "/Library/Group Containers")
        for candidate in [resolved, std] {
            if candidate == containers || candidate.hasPrefix(containers + "/") { return false }
            if candidate == groupC || candidate.hasPrefix(groupC + "/") { return false }
        }

        let personal = [
            h + "/Downloads",
            h + "/Desktop",
            h + "/Documents",
            h + "/Pictures",
            h + "/Movies",
            h + "/Music",
            h + "/.cache",
            h + "/.local/share",
        ].map { standardizeOnly($0) }

        for parent in personal {
            if resolved == parent || std == parent { return false }
            // Prefer resolved location for size; accept either component-boundary under personal
            if resolved.hasPrefix(parent + "/") {
                return byteSize(at: resolved).map { $0 >= LargeFileScanner.minBytes } ?? false
            }
            if std.hasPrefix(parent + "/") {
                // 若 std 在个人目录下但 resolved 已跳出（symlink），上面 secret 应已拦；仍按 resolved 量
                return byteSize(at: fm.fileExists(atPath: resolved) ? resolved : std)
                    .map { $0 >= LargeFileScanner.minBytes } ?? false
            }
        }

        // Application Support: only top-level large folders/files (du -d1 style), not deep nests
        let asRoot = standardizeOnly(h + "/Library/Application Support")
        if resolved == asRoot || std == asRoot { return false }
        if resolved.hasPrefix(asRoot + "/") {
            let rest = String(resolved.dropFirst(asRoot.count + 1))
            guard !rest.isEmpty, !rest.contains("/") else { return false }
            return byteSize(at: resolved).map { $0 >= LargeFileScanner.minBytes } ?? false
        }
        if std.hasPrefix(asRoot + "/") {
            let rest = String(std.dropFirst(asRoot.count + 1))
            guard !rest.isEmpty, !rest.contains("/") else { return false }
            return byteSize(at: std).map { $0 >= LargeFileScanner.minBytes } ?? false
        }
        return false
    }

    private static func byteSize(at path: String) -> UInt64? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            // Shallow: use enumerator with cap — large dirs from C09 already sized by du; here approximate via contents
            guard let vals = try? fm.attributesOfItem(atPath: path),
                  let n = vals[.size] as? NSNumber else {
                return directoryByteSizeCapped(path, cap: LargeFileScanner.minBytes)
            }
            // Directory "size" attr is often small; fall back to capped walk
            if n.uint64Value >= LargeFileScanner.minBytes { return n.uint64Value }
            return directoryByteSizeCapped(path, cap: LargeFileScanner.minBytes)
        }
        guard let vals = try? fm.attributesOfItem(atPath: path),
              let n = vals[.size] as? NSNumber else { return nil }
        return n.uint64Value
    }

    /// Stop once we know path is ≥ minBytes (enough for allow decision).
    private static func directoryByteSizeCapped(_ path: String, cap: UInt64) -> UInt64? {
        let url = URL(fileURLWithPath: path)
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: UInt64 = 0
        var steps = 0
        while let item = en.nextObject() as? URL {
            steps += 1
            if steps > 50_000 { break }
            guard let vals = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true,
                  let sz = vals.fileSize else { continue }
            total += UInt64(sz)
            if total >= cap { return total }
        }
        return total
    }

    // MARK: - Uninstall gate

    /// Can UninstallExecutor recycle this path for the given target app bundle?
    public static func isSafeForUninstall(_ path: String, allowAppBundle: String) -> Bool {
        let appURL = URL(fileURLWithPath: allowAppBundle)
        let bundle = Bundle(url: appURL)
        let identity = UninstallTargetIdentity(
            bundleID: (bundle?.bundleIdentifier ?? "unknown.\(appURL.deletingPathExtension().lastPathComponent)"),
            displayName: (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? appURL.deletingPathExtension().lastPathComponent,
            originalAppPath: allowAppBundle
        )
        return isSafeForUninstall(path, target: identity)
    }

    /// Uses the immutable preflight identity, never re-reading an app that may already
    /// have been moved to Trash.  Container targets additionally require an exact
    /// preflight path and a fresh metadata/live-app check to close the TOCTOU window.
    public static func isSafeForUninstall(_ path: String, target: UninstallTargetIdentity) -> Bool {
        let pathN = normalize(path)
        let allowApp = normalize(target.originalAppPath)
        let lower = pathN.lowercased()

        // Target .app exactly (or files inside that bundle only)
        if !allowApp.isEmpty {
            if pathN == allowApp {
                return pathN.lowercased().hasSuffix(".app")
            }
            if pathN.hasPrefix(allowApp + "/") {
                return allowApp.lowercased().hasSuffix(".app")
            }
        }

        // Any other .app under Applications / user Applications → blocked
        if isAppBundlePath(pathN) {
            return false
        }
        // Paths under /Applications that aren't the target bundle
        if underApplicationsTree(pathN) {
            return false
        }

        if ProtectedMediaRoots.contains(pathN) { return false }
        if isUninstallHardBlocked(pathN) { return false }

        let residualRoots = [
            home + "/Library/Caches",
            home + "/Library/Logs",
            home + "/Library/Saved Application State",
            home + "/Library/HTTPStorages",
            home + "/Library/WebKit",
            home + "/Library/Application Support",
            home + "/Library/Preferences",
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/Application Scripts",
            home + "/Library/LaunchAgents",
            "/Users/Shared"
        ]
        let underAllowed = residualRoots.contains { root in
            let r = normalize(root)
            return pathN == r || pathN.hasPrefix(r + "/")
        }
        guard underAllowed else { return false }

        let forbiddenExact = Set([
            home + "/Library/Caches",
            home + "/Library/Logs",
            home + "/Library/Saved Application State",
            home + "/Library/HTTPStorages",
            home + "/Library/WebKit",
            home + "/Library/Application Support",
            home + "/Library/Preferences",
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/Application Scripts",
            // 禁止整删 LaunchAgents 根；单 plist 子路径由下方 hasSuffix(".plist") 放行
            home + "/Library/LaunchAgents",
            home + "/Library",
            home + "/Music",
            home + "/Movies",
            home + "/Pictures",
            "/",
            "/Applications",
            home + "/Applications",
            "/Users/Shared"
        ].map { normalize($0) })
        if forbiddenExact.contains(pathN) { return false }

        // Preferences / LaunchAgents: only single plist files
        if pathN.hasPrefix(normalize(home + "/Library/Preferences") + "/") {
            return pathN.hasSuffix(".plist")
        }
        if pathN.hasPrefix(normalize(home + "/Library/LaunchAgents") + "/") {
            return pathN.hasSuffix(".plist")
        }

        // Extra blocked under residual trees
        let blocked = [
            home + "/Library/Keychains",
            home + "/Library/Mail",
            home + "/Library/Messages",
            home + "/Library/Mobile Documents"
        ]
        for b in blocked {
            let bl = normalize(b).lowercased()
            if lower == bl || lower.hasPrefix(bl + "/") { return false }
        }

        // Containers / Group Containers / Application Support / Application Scripts：
        // 直接子项必须与目标 App 有可解释归属（bid 组件边界或唯一规范名），禁止「整树可卸」。
        if isContainerPath(pathN) {
            guard target.verifiedResidualPaths.contains(pathN),
                  let inspected = freshContainerOwnership(pathN),
                  inspected.confidence == .verifiedOrphan,
                  inspected.bundleID?.caseInsensitiveCompare(target.bundleID) == .orderedSame
            else { return false }
        } else if !residualLeafBelongsToApp(pathN: pathN, target: target) {
            return false
        }

        return true
    }

    /// 对高敏 residual 根（容器 / AS）：路径相对根的第一段须归属目标 App。
    /// Caches/Logs 等仍靠上游 ResidualMatcher 归属 + 禁止整根 forbiddenExact。
    private static func residualLeafBelongsToApp(pathN: String, target: UninstallTargetIdentity) -> Bool {
        let ownershipRoots = [
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/Application Support",
            home + "/Library/Application Scripts"
        ].map { normalize($0) }

        guard let root = ownershipRoots.first(where: { pathN == $0 || pathN.hasPrefix($0 + "/") }) else {
            // 不在上述根下（如 /Users/Shared 子路径）：不额外拦
            return true
        }
        // 根本身已在 forbiddenExact
        guard pathN.hasPrefix(root + "/") else { return true }

        let rest = String(pathN.dropFirst(root.count + 1))
        let leaf = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? rest
        guard !leaf.isEmpty else { return false }

        // Construct from preflight data, not the on-disk .app (it may be gone).
        let app = InstalledApp(
            name: target.displayName,
            bundleIdentifier: target.bundleID,
            path: target.originalAppPath,
            version: "—",
            bytes: 0,
            relatedBytes: 0,
            isSystemLocation: false,
            canTrashAppBundle: true
        )
        return AppOwnership.folderBelongs(to: app, folderName: leaf, path: pathN)
    }

    private static func isContainerPath(_ path: String) -> Bool {
        let containers = normalize(home + "/Library/Containers")
        let groups = normalize(home + "/Library/Group Containers")
        return path.hasPrefix(containers + "/") || path.hasPrefix(groups + "/")
    }

    private static func freshContainerOwnership(_ path: String) -> ContainerOwnership? {
        let containers = normalize(home + "/Library/Containers")
        let groups = normalize(home + "/Library/Group Containers")
        let isGroup = path.hasPrefix(groups + "/")
        guard path.hasPrefix(containers + "/") || isGroup else { return nil }
        let apps = AppInventory.fetchInstalledApps(includeSystemApps: true, computeSize: false)
        return ContainerOwnershipScanner.inspect(path: path, isGroupContainer: isGroup, installed: apps)
    }

    // MARK: - Trash permanent delete helper

    public static func isUnderUserTrash(_ path: String) -> Bool {
        let trash = (home as NSString).appendingPathComponent(".Trash")
        let lower = normalize(path).lowercased()
        let t = normalize(trash).lowercased()
        return lower == t || lower.hasPrefix(t + "/")
    }

    // MARK: - Prefix tables

    private static func dockerAllowPrefixes(home homePath: String? = nil) -> [String] {
        let h = homePath ?? home
        return [
            "\(h)/Library/Containers/com.docker.docker/Data/cache",
            "\(h)/Library/Containers/com.docker.docker/Data/log",
            "\(h)/Library/Containers/com.docker.docker/Data/tmp",
            "\(h)/Library/Group Containers/group.com.docker/Caches",
            "\(h)/.docker/cli-plugins/.cache",
            "\(h)/.docker/buildx/cache"
        ]
    }

    private static func aiAllowPrefixes(home homePath: String? = nil) -> [String] {
        let h = homePath ?? home
        return [
            "\(h)/.ollama",
            "\(h)/.lmstudio",
            "\(h)/Library/WebKit/com.electron.ollama",
            "\(h)/Library/Saved Application State/com.electron.ollama.savedState"
        ]
    }

    /// CLI tool user data dirs (MacDefier §7.3.1 L2). Exact product folders only — not whole `~`.
    public static func cliDataAllowPrefixes(home homePath: String? = nil) -> [String] {
        let h = homePath ?? home
        return [
            "\(h)/.openclaw",
            "\(h)/.codex",
            "\(h)/.claude",
            "\(h)/.kimi",
            "\(h)/.kimi-code",
            "\(h)/.local/share/opencode",
            "\(h)/.config/opencode",
            "\(h)/.gemini",
            "\(h)/.aider",
            "\(h)/.grok",
            "\(h)/.hermes",
        ]
    }

    private static func junkAllowPrefixes(home homePath: String? = nil) -> [String] {
        let h = homePath ?? home
        return [
            h + "/Library/Caches",
            h + "/Library/Logs",
            h + "/Library/Developer",
            h + "/.Trash",
            h + "/.npm",
            h + "/.cache",
            h + "/Library/pnpm",
            h + "/Library/Application Support/CrashReporter",
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log",
            "/var/log",
            "/private/var/tmp",
            "/var/tmp",
            "/private/tmp",
            "/tmp",
            "/opt/homebrew/Library/Caches",
            "/usr/local/Homebrew/Library/Caches",
            NSTemporaryDirectory()
        ]
    }

    private static func trashAllowPrefixes(home homePath: String? = nil) -> [String] {
        let h = homePath ?? home
        return junkAllowPrefixes(home: h) + [
            h + "/Library/Saved Application State",
            h + "/Library/HTTPStorages",
            h + "/Library/WebKit",
            h + "/.docker/cli-plugins/.cache",
            h + "/.docker/buildx/cache",
            h + "/Library/WebKit/com.electron.ollama",
            h + "/Library/Saved Application State/com.electron.ollama.savedState",
            h + "/Library/Containers/com.docker.docker/Data/cache",
            h + "/Library/Containers/com.docker.docker/Data/log",
            h + "/Library/Containers/com.docker.docker/Data/tmp",
            h + "/Library/Group Containers/group.com.docker/Caches"
        ]
    }

    /// 浏览器密码/登录库：不得仅靠 risk.skip，PathGate 硬拒（审查 F03-3）
    public static func isBrowserCredentialPath(_ path: String) -> Bool {
        let name = (normalize(path) as NSString).lastPathComponent.lowercased()
        let blocked = [
            "login data", "login data-journal",
            "web data", "web data-journal",
            "logins.json", "key4.db", "key3.db", "logins-backup.json",
            "cookies", "cookies-journal",
            "account.values", // Safari-ish
        ]
        if blocked.contains(name) { return true }
        // Chrome/Edge: "Login Data", "Login Data For Account"
        if name.hasPrefix("login data") { return true }
        if name.hasPrefix("web data") { return true }
        return false
    }

    /// Allow 前缀：组件边界；allow 根/中途 symlink 落入敏感区则拒绝；解析后必须仍在 allow 根内（fail-closed）。
    /// M03-1：不得 early-true 绕过密钥/个人数据硬闸。
    private static func underAllowedPrefix(_ path: String, _ prefixes: [String], home homePath: String) -> Bool {
        let std = standardizeOnly(path)
        let resolved = normalize(path)
        // 解析前后任一命中敏感/密钥：绝不因 allow 放行
        if isSensitiveHardBlocked(path, home: homePath) { return false }

        for prefix in prefixes {
            let raw = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            let p = standardizeOnly(raw)
            let allowResolved = normalize(p)

            let matchesStd = std == p || std.hasPrefix(p + "/")
            let underAllowResolved =
                resolved == allowResolved || resolved.hasPrefix(allowResolved + "/")

            // Only inspect a matching allow root. Previously every candidate checked
            // every unrelated root against the entire hard-block table (with I/O).
            // Still resolve each root, so safe root aliases remain supported, and
            // retain both hard gates before any grant. No cross-call safety cache.
            guard matchesStd || (allowResolved != p && underAllowResolved) else { continue }
            if isSensitiveHardBlocked(p, home: homePath) { continue }
            if isSensitiveHardBlocked(allowResolved, home: homePath) { continue }

            if matchesStd {
                // 写面在 allow 下：解析后必须仍在 allow 根内（拒中途 symlink 逃逸）
                if underAllowResolved { return true }
                // leaf 不存在时 resolved 常与 std 相同
                if resolved == std { return true }
                continue
            }

            // 路径以「解析后的 allow 根」形式给出（allow 根是安全 symlink）
            if allowResolved != p, underAllowResolved {
                return true
            }
        }
        return false
    }

    private static func isAppBundlePath(_ path: String) -> Bool {
        // 仅当某一路径组件以「.app」为扩展名（如 Foo.app），或路径穿过 Foo.app/
        // 避免把 Caches/com.vendor.app 这种 bid 目录误判成应用包（pathExtension 也会是 app）
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for (idx, part) in parts.enumerated() {
            let lower = part.lowercased()
            guard lower.hasSuffix(".app"), lower.count > 4 else { continue }
            // reverse-DNS 目录极少整段叫 x.app；真 .app 包通常 Title Case 或无多段点号
            // 保守：含 ".app/" 子路径，或组件恰好是 Name.app 且前面是 Applications 树 / 用户目录
            if idx + 1 < parts.count { return true } // .../Something.app/Contents/...
            // leaf Something.app
            if lower.filter({ $0 == "." }).count == 1 { return true } // "Foo.app"
            // "com.foo.app" as leaf: 不当作应用包（常见 cache/container 命名）
            return false
        }
        return false
    }

    private static func underApplicationsTree(_ path: String) -> Bool {
        let apps = normalize("/Applications")
        let userApps = normalize(home + "/Applications")
        return path == apps || path.hasPrefix(apps + "/")
            || path == userApps || path.hasPrefix(userApps + "/")
    }
}
