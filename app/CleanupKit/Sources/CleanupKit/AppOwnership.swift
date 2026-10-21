// AppOwnership — shared residual / orphan / channel path attribution.
// Priority: metadata exact > full Bundle ID > Bundle ID component boundary > unique normalized name.
// No bare contains / bidirectional short-token matching.

import Foundation

public enum AppOwnership {
    /// 通用 token：不参与名称归属（vendor/app/helper/service…）
    /// 与 AppInventory fuzzy 黑名单同源（M05-1）。
    public static let genericTokens: Set<String> = MatchingSegments.stopwords.union([
        "vendor", "application", "applications", "bundle", "framework",
        "launcher", "updater", "installer", "uninstaller", "extension", "plugin",
        "daemon", "xpc", "login", "agent", "helper", "service", "services",
        "app", "apps", "client", "desktop", "ui", "gui", "core", "kit",
        "google", "microsoft", "apple", "adobe", "amazon", "meta", "common", "shared", "support",
        "com", "org", "net", "mac", "macos", "osx", "ios",
        "chrome", "chromium", "drive", "drivefs", "docs", "slides", "sheets", "web",
        "update", "sdk", "studio"
    ])

    /// Vendor 大根目录：禁止仅凭子 App 名称模糊认领整树（与 AppInventory 同源）。
    public static let vendorMegaFolderNames: Set<String> = [
        "google", "adobe", "microsoft", "apple", "docker", "steam", "unity",
        "epic games", "epicgames", "jetbrains", "android", "androidstudio",
        "mozilla", "chromium", "dropbox", "onedrive", "icloud"
    ]

    // MARK: - Folder ownership for one app (residuals)

    /// 目录名/路径是否可归属给该 App（用于 ResidualMatcher 扫描根）。
    public static func folderBelongs(
        to app: InstalledApp,
        folderName: String,
        path: String,
        uniqueNormalizedNames: Set<String> = []
    ) -> Bool {
        // 1) UUID 容器 metadata 精确归属
        if isUUIDContainerOwned(path: path, bundleID: app.bundleIdentifier) {
            return true
        }

        // 2) 完整 Bundle ID（组件边界）
        if bundleIDMatches(folderName: folderName, bundleID: app.bundleIdentifier) {
            return true
        }
        // 路径中出现完整 bid 组件序列（非裸 contains）
        if bundleIDAppearsInPath(path: path, bundleID: app.bundleIdentifier) {
            return true
        }

        // 3) 名称精确相等（非 contains / 非 reverse-DNS 子串）
        // reverse-DNS 风格目录禁止名称认领 → 防 Hermes→com.hermes.p6game
        if looksLikeReverseDNS(folderName) {
            return false
        }
        if isVendorMegaFolder(folderName) {
            return false
        }

        let normFolder = folderName.mdNormalizedForMatching()
        let normApp = app.name.mdNormalizedForMatching()
        let baseName = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
        let normBase = baseName.mdNormalizedForMatching()

        if normFolder.count >= 5,
           !isGenericToken(normFolder),
           (normFolder == normApp || normFolder == normBase) {
            // 若提供了唯一名集合，必须在集合内；未提供时仍要求自身名称非通用
            if uniqueNormalizedNames.isEmpty {
                return true
            }
            if uniqueNormalizedNames.contains(normFolder) {
                return true
            }
        }

        // 带 .plist / .savedState 后缀：仅 bid 组件边界或 stem 精确名（stem 不得为 reverse-DNS 误匹配）
        for suffix in [".plist", ".savedstate", ".savedState"] {
            if folderName.lowercased().hasSuffix(suffix.lowercased()) {
                let stem = String(folderName.dropLast(suffix.count))
                if bundleIDMatches(folderName: stem, bundleID: app.bundleIdentifier) {
                    return true
                }
                if looksLikeReverseDNS(stem) { continue }
                let ns = stem.mdNormalizedForMatching()
                if ns.count >= 5, !isGenericToken(ns),
                   (ns == normApp || ns == normBase),
                   (uniqueNormalizedNames.isEmpty || uniqueNormalizedNames.contains(ns)) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Owned by any installed app (orphans)

    /// 目录是否仍被已装 App 拥有（是则不是 orphan）。
    public static func isOwnedByInstalled(
        name: String,
        path: String,
        apps: [InstalledApp],
        uniqueNormalizedNames: Set<String>? = nil
    ) -> Bool {
        let uniqueNames = uniqueNormalizedNames ?? uniqueNormalizedNameSet(from: apps)

        // metadata first
        if name.count == 36, name.contains("-") {
            let meta = (path as NSString).appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let dict = NSDictionary(contentsOfFile: meta),
               let bid = dict["MCMMetadataIdentifier"] as? String {
                let lower = bid.lowercased()
                if apps.contains(where: { $0.bundleIdentifier.lowercased() == lower }) {
                    return true
                }
            }
        }

        for app in apps {
            if folderBelongs(to: app, folderName: name, path: path, uniqueNormalizedNames: uniqueNames) {
                return true
            }
        }
        return false
    }

    // MARK: - Bundle ID component boundary

    /// `com.foo.app` 仅匹配完整组件或以 `.` 为边界的子组件序列；不匹配 `com.foobar.app`。
    public static func bundleIDMatches(folderName: String, bundleID: String) -> Bool {
        let bid = bundleID.lowercased()
        guard bid.count >= 5 else { return false }
        var cand = folderName.lowercased()
        for suffix in [".plist", ".savedstate"] {
            if cand.hasSuffix(suffix) {
                cand = String(cand.dropLast(suffix.count))
            }
        }
        if cand == bid { return true }
        if cand.hasPrefix(bid + ".") { return true }

        let bidParts = bid.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        let candParts = cand.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        // 至少 2 段 bundle 才用滑动窗口，避免单段 token 误伤
        guard bidParts.count >= 2, candParts.count >= bidParts.count else { return false }
        for i in 0...(candParts.count - bidParts.count) {
            if Array(candParts[i..<(i + bidParts.count)]) == bidParts {
                return true
            }
        }
        return false
    }

    public static func bundleIDAppearsInPath(path: String, bundleID: String) -> Bool {
        let bid = bundleID.lowercased()
        guard bid.count >= 5 else { return false }
        let parts = path.split(separator: "/").map { String($0).lowercased() }
        for part in parts {
            if bundleIDMatches(folderName: part, bundleID: bid) { return true }
        }
        return false
    }

    // MARK: - Channel paths (Chrome / Drive) — single table for Inventory + Residual

    /// Chromium / Drive 通道路径表；与 AppInventory related 共用。
    public static func channelRelatedPaths(
        bundleID: String,
        appPath: String,
        home: String
    ) -> [String] {
        // Chrome Apps (Telegram Web etc.): shell only
        if appPath.contains("Chrome Apps") || bundleID.contains("com.google.Chrome.app.") {
            return []
        }
        var out: [String] = []
        if bundleID == "com.google.Chrome.beta"
            || bundleID.hasPrefix("com.google.Chrome.beta")
            || appPath.localizedCaseInsensitiveContains("Chrome Beta") {
            out += [
                "\(home)/Library/Application Support/Google/Chrome Beta",
                "\(home)/Library/Caches/Google/Chrome Beta"
            ]
        } else if bundleID == "com.google.Chrome.canary"
            || bundleID.hasPrefix("com.google.Chrome.canary")
            || appPath.localizedCaseInsensitiveContains("Chrome Canary") {
            out += [
                "\(home)/Library/Application Support/Google/Chrome Canary",
                "\(home)/Library/Caches/Google/Chrome Canary"
            ]
        } else if bundleID == "com.google.Chrome.dev"
            || bundleID.hasPrefix("com.google.Chrome.dev")
            || appPath.localizedCaseInsensitiveContains("Chrome Dev") {
            out += [
                "\(home)/Library/Application Support/Google/Chrome Dev",
                "\(home)/Library/Caches/Google/Chrome Dev"
            ]
        } else if bundleID == "com.google.Chrome" {
            out += [
                "\(home)/Library/Application Support/Google/Chrome",
                "\(home)/Library/Caches/Google/Chrome"
            ]
        } else if bundleID.hasPrefix("com.google.Chrome.") {
            // Unknown Chrome.* channel — do not attach stable profile
        }
        if bundleID == "com.google.drivefs" || bundleID.hasPrefix("com.google.drivefs.") {
            out += ["\(home)/Library/Application Support/Google/DriveFS"]
        }
        return out
    }

    // MARK: - Deep-link resolution

    public enum DeepLinkResolution: Sendable {
        case exact(InstalledApp)
        case ambiguous([InstalledApp])
        case none
    }

    /// 卸载深链：精确 path > 精确 Bundle ID > 名称精确且唯一。
    public static func resolveDeepLink(
        path: String?,
        bundleID: String?,
        name: String?,
        in apps: [InstalledApp]
    ) -> DeepLinkResolution {
        if let path, let hit = apps.first(where: { $0.path == path }) {
            return .exact(hit)
        }
        if let bundleID, !bundleID.isEmpty {
            let lower = bundleID.lowercased()
            let hits = apps.filter { $0.bundleIdentifier.lowercased() == lower }
            if hits.count == 1 { return .exact(hits[0]) }
            if hits.count > 1 { return .ambiguous(hits) }
        }
        if let name, !name.isEmpty {
            let lower = name.lowercased()
            let exact = apps.filter {
                $0.name.lowercased() == lower
                    || URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent.lowercased() == lower
            }
            if exact.count == 1 { return .exact(exact[0]) }
            if exact.count > 1 { return .ambiguous(exact) }
            // 非精确名称：不自动打开第一个
        }
        return .none
    }

    // MARK: - Helpers

    public static func isGenericToken(_ token: String) -> Bool {
        let t = token.lowercased()
        if t.count < 5 { return true }
        return genericTokens.contains(t)
    }

    /// Vendor 大根（google / microsoft …）不可被名称模糊认领。
    public static func isVendorMegaFolder(_ folderName: String) -> Bool {
        vendorMegaFolderNames.contains(folderName.lowercased())
    }

    /// reverse-DNS / 多段 Bundle 风格名：禁止仅凭应用显示名 contains/相等认领。
    /// 例：`com.hermes.p6game`、`ai.hermes.gateway.plist`、`group.com.foo.bar`。
    public static func looksLikeReverseDNS(_ folderName: String) -> Bool {
        var cand = folderName
        for suffix in [".plist", ".savedstate", ".savedState"] {
            if cand.lowercased().hasSuffix(suffix.lowercased()) {
                cand = String(cand.dropLast(suffix.count))
            }
        }
        let parts = cand.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return false }
        // 至少一段像 DNS 标签且整体不像「My.App Name」单品牌
        let joined = parts.joined(separator: ".").lowercased()
        if joined.hasPrefix("com.") || joined.hasPrefix("org.") || joined.hasPrefix("net.")
            || joined.hasPrefix("io.") || joined.hasPrefix("ai.") || joined.hasPrefix("app.")
            || joined.hasPrefix("group.") {
            return true
        }
        // TEAMID.xxx 组容器 / 通用多段 reverse-DNS（全小写标签、无空格）
        let allLabels = parts.allSatisfy { part in
            let p = part.lowercased()
            return !p.isEmpty
                && p.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
                && !p.contains(" ")
        }
        return allLabels && parts.count >= 2 && cand.count >= 8
    }

    public static func uniqueNormalizedNameSet(from apps: [InstalledApp]) -> Set<String> {
        var counts: [String: Int] = [:]
        for app in apps {
            // A typical app has the same display name and bundle filename
            // (for example Cursor + Cursor.app). Count that identity once for
            // this app; otherwise every such name looks globally ambiguous and
            // its live Application Support folder is misreported as an orphan.
            let names = Set([
                app.name.mdNormalizedForMatching(),
                URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.mdNormalizedForMatching()
            ])
            for n in names where n.count >= 5 && !isGenericToken(n) {
                counts[n, default: 0] += 1
            }
        }
        return Set(counts.compactMap { $0.value == 1 ? $0.key : nil })
    }

    private static func isUUIDContainerOwned(path: String, bundleID: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.count == 36, name.contains("-") else { return false }
        let meta = (path as NSString).appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let dict = NSDictionary(contentsOfFile: meta),
              let owner = dict["MCMMetadataIdentifier"] as? String
        else { return false }
        return owner.lowercased() == bundleID.lowercased()
    }
}
