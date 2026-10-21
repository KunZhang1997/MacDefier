// ResidualMatcher — AppPathFinder-inspired residual discovery (PureMac MIT subset).
// Strict/Enhanced matching; min token length 5; Locations subset for uninstall UI.

import Foundation

public enum ResidualMatchSensitivity: Sendable {
    case strict
    case enhanced
}

public enum ResidualMatcher {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let fm = FileManager.default
    private static let minToken = 5

    /// High-hit Library roots (depth 1). Not full PureMac 120+ table.
    private static var searchRoots: [String] {
        [
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
            "\(home)/Library/Preferences",
            "\(home)/Library/Application Support",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Application Scripts"
        ]
    }

    public static func findResiduals(
        for app: InstalledApp,
        sensitivity: ResidualMatchSensitivity = .enhanced
    ) -> [ResidualItem] {
        var items: [ResidualItem] = []
        var seen = Set<String>()

        func append(path: String, kind: ResidualKind, note: String) {
            let key = normalize(path)
            guard seen.insert(key).inserted else { return }
            guard fm.fileExists(atPath: path) else { return }
            if path == app.path { return }
            items.append(ResidualItem(
                path: path,
                kind: kind,
                bytes: quickSize(path),
                note: note
            ))
        }

        items.append(ResidualItem(
            path: app.path,
            kind: .appBundle,
            bytes: app.bytes, // package only; related data listed separately below
            note: "主程序包 · 卸掉后应用不可用（默认勾选 · 进废纸篓）"
        ))
        seen.insert(normalize(app.path))

        // Exact high-hit candidates first
        for (path, kind, note) in exactCandidates(app: app) {
            append(path: path, kind: kind, note: note)
        }

        // Chrome / Drive 通道表（与 AppInventory 同一份）
        for path in AppOwnership.channelRelatedPaths(
            bundleID: app.bundleIdentifier,
            appPath: app.path,
            home: home
        ) {
            append(path: path, kind: .support, note: "通道专属数据 · 默认保留")
        }

        // 扫描根：共享归属判定（无裸 contains）
        // uniqueNormalizedNames 在单 app residual 扫描时为空 → 仅当名称完整相等且非通用才命中
        for root in searchRoots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            // Do not silently truncate Containers: several real installations have
            // more than 600 entries.  This runs off-main and observes cancellation.
            for name in names {
                if Task.isCancelled { return filterSubpaths(items) }
                if name.hasPrefix(".") { continue }
                let path = (root as NSString).appendingPathComponent(name)
                guard matches(folderName: name, path: path, app: app, sensitivity: sensitivity) else {
                    continue
                }
                // Preferences: only plists
                if root.hasSuffix("/Preferences"), !name.hasSuffix(".plist") { continue }
                let kind = kindFor(path: path)
                let note = noteFor(kind: kind)
                append(path: path, kind: kind, note: note)
            }
        }

        // UUID containers via metadata
        for path in discoverUUIDContainers(bundleID: app.bundleIdentifier) {
            append(path: path, kind: .containers, note: "沙盒容器（metadata 归属）· 默认保留")
        }

        // Known external media libraries
        for (path, kind, note) in knownExternal(app: app) {
            append(path: path, kind: kind, note: note)
        }

        return filterSubpaths(items)
    }

    // MARK: - Matching

    /// 残留目录归属（M05-1）：metadata / 完整 bid 边界优先；禁止 reverse-DNS contains、vendor 大根、容器名-only。
    /// 包内可见供单测驱动 shipped 路径（非 UI）。
    static func matches(
        folderName: String,
        path: String,
        app: InstalledApp,
        sensitivity: ResidualMatchSensitivity
    ) -> Bool {
        // 共享归属：metadata > 完整 bid 组件边界 > 规范化名称精确（已禁 reverse-DNS 名认领）
        if AppOwnership.folderBelongs(to: app, folderName: folderName, path: path) {
            return true
        }
        // strict：不再做任何放宽
        if sensitivity == .strict { return false }

        // enhanced：允许 base bundle（去掉 helper/service 后缀）按组件边界匹配
        if let base = app.bundleIdentifier.mdBaseBundleIdentifier,
           AppOwnership.bundleIDMatches(folderName: folderName, bundleID: base) {
            return true
        }

        // Containers / Group Containers / Application Scripts / LaunchAgents：仅 bid/metadata
        // （名称 token 曾导致 Hermes→com.hermes.p6game、Developer→STMExtension）
        if isBidOnlyRoot(path) {
            return false
        }

        // reverse-DNS / vendor 大根：禁止名称 exact 放宽
        if AppOwnership.looksLikeReverseDNS(folderName) { return false }
        if AppOwnership.isVendorMegaFolder(folderName) { return false }

        // enhanced：去版本后缀后的应用名精确相等（非 contains、非子串）
        let stripped = app.name.mdStrippingTrailingVersion().mdNormalizedForMatching()
        let normFolder = folderName.mdNormalizedForMatching()
        if stripped.count >= minToken,
           !AppOwnership.isGenericToken(stripped),
           !AppOwnership.isGenericToken(normFolder),
           normFolder == stripped {
            return true
        }
        return false
    }

    /// 容器/脚本/LaunchAgent：禁止仅凭显示名认领。
    private static func isBidOnlyRoot(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("/library/containers/")
            || p.contains("/library/group containers/")
            || p.contains("/library/application scripts/")
            || p.contains("/library/launchagents/")
    }

    // MARK: - Exact + external

    private static func exactCandidates(app: InstalledApp) -> [(String, ResidualKind, String)] {
        let bid = app.bundleIdentifier
        return [
            ("\(home)/Library/Caches/\(bid)", .cache, "应用缓存，可重建"),
            ("\(home)/Library/Logs/\(bid)", .logs, "应用日志"),
            ("\(home)/Library/Saved Application State/\(bid).savedState", .savedState, "窗口恢复状态"),
            ("\(home)/Library/HTTPStorages/\(bid)", .cache, "网络存储缓存"),
            ("\(home)/Library/WebKit/\(bid)", .cache, "WebKit 数据"),
            ("\(home)/Library/Preferences/\(bid).plist", .preferences, "偏好设置 · 默认保留"),
            ("\(home)/Library/Application Support/\(bid)", .support, "应用支持文件 · 默认保留"),
            ("\(home)/Library/Application Support/\(app.name)", .support, "应用支持文件（按名）· 默认保留"),
            ("\(home)/Library/Containers/\(bid)", .containers, "沙盒容器 · 默认保留"),
            ("\(home)/Library/Group Containers/\(bid)", .containers, "组容器 · 默认保留"),
            ("\(home)/Library/LaunchAgents/\(bid).plist", .other, "用户 LaunchAgent · 默认保留"),
            ("\(home)/Library/Application Scripts/\(bid)", .other, "Application Scripts · 默认保留"),
            ("\(home)/Library/Caches/com.apple.nsurlsessiond/Downloads/\(bid)", .cache, "NSURLSession 下载缓存")
        ]
    }

    private static func knownExternal(app: InstalledApp) -> [(String, ResidualKind, String)] {
        switch app.bundleIdentifier {
        case "com.apple.Music":
            return [
                ("\(home)/Music/Music Library.musiclibrary", .mediaLibrary, "音乐资料库 · 默认保留"),
                ("\(home)/Music/Music", .mediaLibrary, "音乐媒体目录 · 默认保留")
            ]
        case "com.apple.TV":
            return [
                ("\(home)/Movies/TV", .mediaLibrary, "Apple TV 媒体库 · 默认保留"),
                ("\(home)/Movies/Videos", .mediaLibrary, "视频媒体目录 · 默认保留")
            ]
        case "com.apple.Photos":
            return [
                ("\(home)/Pictures/Photos Library.photoslibrary", .mediaLibrary, "照片图库 · 默认保留")
            ]
        default:
            return []
        }
    }

    private static func discoverUUIDContainers(bundleID: String) -> [String] {
        let root = "\(home)/Library/Containers"
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [String] = []
        for name in dirs {
            guard name.count == 36, name.contains("-") else { continue }
            let dir = (root as NSString).appendingPathComponent(name)
            let meta = (dir as NSString).appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            guard let dict = NSDictionary(contentsOfFile: meta),
                  let owner = dict["MCMMetadataIdentifier"] as? String,
                  owner == bundleID
            else { continue }
            out.append(dir)
        }
        return out
    }

    // MARK: - Kind / size / filter

    private static func kindFor(path: String) -> ResidualKind {
        let p = path
        if p.contains("/Library/Caches/") { return .cache }
        if p.contains("/Library/Logs/") { return .logs }
        if p.contains("/Saved Application State/") { return .savedState }
        if p.contains("/HTTPStorages/") || p.contains("/WebKit/") { return .cache }
        if p.contains("/Library/Preferences/") { return .preferences }
        if p.contains("/Library/Containers/") || p.contains("/Group Containers/") { return .containers }
        if p.contains("/Application Support/") { return .support }
        return .other
    }

    private static func noteFor(kind: ResidualKind) -> String {
        switch kind {
        case .appBundle: return "主程序包"
        case .cache: return "缓存 · 可重建"
        case .logs: return "日志"
        case .savedState: return "窗口恢复状态"
        case .support: return "支持文件 · 默认保留"
        case .preferences: return "偏好设置 · 默认保留"
        case .containers: return "容器 · 可能含用户数据 · 默认保留"
        case .mediaLibrary: return "媒体库 · 默认保留"
        case .other: return "关联文件 · 默认保留"
        }
    }

    private static func filterSubpaths(_ items: [ResidualItem]) -> [ResidualItem] {
        let sorted = items.sorted { $0.path.count < $1.path.count }
        var kept: [ResidualItem] = []
        for item in sorted {
            let p = normalize(item.path)
            if kept.contains(where: { p.hasPrefix(normalize($0.path) + "/") }) {
                continue
            }
            kept.removeAll { normalize($0.path).hasPrefix(p + "/") }
            kept.append(item)
        }
        return kept.sorted { $0.bytes > $1.bytes }
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func quickSize(_ path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var total: UInt64 = 0
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var n = 0
        for case let f as URL in en {
            n += 1
            if n > 20_000 { break }
            if let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true {
                total += UInt64(v.fileSize ?? 0)
            }
        }
        return total
    }
}
