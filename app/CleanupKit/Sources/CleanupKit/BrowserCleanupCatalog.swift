// Browser cleanup path catalog — Safari / Chrome / Edge only (C08).
// Paths learned from market/open-source practice; no GPL code copied.
// Product: per browser × data kind; preview → trashItem; passwords never default-on.

import AppKit
import Foundation

public enum BrowserDataKind: String, Sendable {
    case cache
    case history
    case downloads
    case cookies
    case siteData
    case passwords

    public var title: String {
        switch self {
        case .cache: return "缓存"
        case .history: return "浏览记录"
        case .downloads: return "下载记录"
        case .cookies: return "Cookie / 登录态"
        case .siteData: return "网站数据"
        case .passwords: return "已存密码"
        }
    }

    public var risk: CleanupRisk {
        switch self {
        case .cache: return .rebuild
        case .history, .downloads: return .caution
        case .cookies, .siteData: return .caution
        case .passwords: return .skip
        }
    }

    public var what: String {
        switch self {
        case .cache: return "页面/图片/脚本等可再生缓存（含 GPU/Code/Service Worker 缓存）"
        case .history: return "地址栏与历史记录库"
        case .downloads: return "浏览器内的下载列表记录（一般不删已下文件本体）"
        case .cookies: return "网站 Cookie，清后多数站点会退出登录"
        case .siteData: return "Local Storage / IndexedDB 等本地网站数据"
        case .passwords: return "浏览器已保存的账号密码库（极高敏）"
        }
    }

    public var effect: String {
        switch self {
        case .cache: return "网站可能暂时变慢，会重新下载资源；不丢书签/账号密码"
        case .history: return "历史记录清空；书签一般还在"
        case .downloads: return "下载列表清空；已下载到「下载」文件夹的文件通常还在"
        case .cookies: return "多数网站需重新登录"
        case .siteData: return "站点离线数据/部分设置丢失，可能要重新登录"
        case .passwords: return "本机保存的网站密码可能丢失；Safari 密码多在钥匙串，此项主要针对 Chromium"
        }
    }
}

public enum BrowserBrand: String, Sendable, CaseIterable {
    case safari
    case chrome
    case edge

    public var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        }
    }

    /// Process names for running check
    public var processNames: [String] {
        switch self {
        case .safari: return ["Safari"]
        case .chrome: return ["Google Chrome", "Google Chrome Helper"]
        case .edge: return ["Microsoft Edge", "Microsoft Edge Helper"]
        }
    }

    public var isRunning: Bool {
        BrowserCleanupGuard.live.processState(self) == .inUse
    }
}

enum BrowserCleanupCatalog {
    struct Spec {
        let brand: BrowserBrand
        let kind: BrowserDataKind
        let paths: [String]
    }

    static func specs(home: String, fm: FileManager) -> [Spec] {
        var out: [Spec] = []
        out.append(contentsOf: safariSpecs(home: home))
        out.append(contentsOf: chromiumSpecs(
            brand: .chrome,
            home: home,
            fm: fm,
            cacheRoots: [
                "\(home)/Library/Caches/Google/Chrome"
            ],
            supportRoot: "\(home)/Library/Application Support/Google/Chrome"
        ))
        out.append(contentsOf: chromiumSpecs(
            brand: .edge,
            home: home,
            fm: fm,
            cacheRoots: [
                "\(home)/Library/Caches/Microsoft Edge",
                "\(home)/Library/Caches/com.microsoft.edgemac"
            ],
            supportRoot: "\(home)/Library/Application Support/Microsoft Edge"
        ))
        // Edge alternate support folder on some installs
        let edgeAlt = "\(home)/Library/Application Support/Microsoft Edge"
        if !fm.fileExists(atPath: edgeAlt) {
            out.append(contentsOf: chromiumSpecs(
                brand: .edge,
                home: home,
                fm: fm,
                cacheRoots: [],
                supportRoot: "\(home)/Library/Application Support/com.microsoft.edgemac"
            ))
        }
        return out
    }

    private static func safariSpecs(home: String) -> [Spec] {
        [
            Spec(brand: .safari, kind: .cache, paths: [
                "\(home)/Library/Caches/com.apple.Safari",
                "\(home)/Library/Caches/CloudKit/com.apple.Safari",
                "\(home)/Library/WebKit/com.apple.Safari",
                "\(home)/Library/HTTPStorages/com.apple.Safari"
            ]),
            Spec(brand: .safari, kind: .history, paths: [
                "\(home)/Library/Safari/History.db",
                "\(home)/Library/Safari/History.db-wal",
                "\(home)/Library/Safari/History.db-shm",
                "\(home)/Library/Safari/HistoryIndex.sk",
                "\(home)/Library/Safari/RecentlyClosedTabs.plist",
                "\(home)/Library/Safari/TopSites.db",
                "\(home)/Library/Safari/LastSession.plist"
            ]),
            Spec(brand: .safari, kind: .downloads, paths: [
                "\(home)/Library/Safari/Downloads.plist"
            ]),
            // Safari cookies: `~/Library/Cookies/Cookies.binarycookies` 是多 App 共用的系统
            // Cookie 罐（非 Safari 独占）。作为可清项会登出全机登录态 → 不生成可执行项，
            // 引导用户到 Safari / 系统设置管理。
            Spec(brand: .safari, kind: .siteData, paths: [
                "\(home)/Library/Safari/LocalStorage",
                "\(home)/Library/Safari/Databases",
                "\(home)/Library/Safari/IndexedDB"
            ])
            // passwords: Safari keychain — no file-level fake “clear passwords”
        ]
    }

    private static func chromiumSpecs(
        brand: BrowserBrand,
        home: String,
        fm: FileManager,
        cacheRoots: [String],
        supportRoot: String
    ) -> [Spec] {
        var cachePaths = cacheRoots
        var history: [String] = []
        var downloads: [String] = []
        var site: [String] = []
        var passwords: [String] = []

        let profiles = chromiumProfiles(in: supportRoot, fm: fm)
        for profile in profiles {
            cachePaths += [
                "\(profile)/Cache",
                "\(profile)/Code Cache",
                "\(profile)/GPUCache",
                "\(profile)/DawnCache",
                "\(profile)/DawnGraphiteCache",
                "\(profile)/DawnWebGPUCache",
                "\(profile)/GrShaderCache",
                "\(profile)/ShaderCache",
                "\(profile)/Service Worker/CacheStorage"
            ]
            history += [
                "\(profile)/History",
                "\(profile)/History-journal",
                "\(profile)/Visited Links",
                "\(profile)/Top Sites",
                "\(profile)/Top Sites-journal"
            ]
            downloads += [
                "\(profile)/DownloadMetadata",
                "\(profile)/Download Service"
            ]
            // 产品决策：Cookie 不进入清理列表（PathGate 继续硬拒）；不提供 Cookie 清理功能
            site += [
                "\(profile)/Local Storage",
                "\(profile)/Session Storage",
                "\(profile)/IndexedDB",
                "\(profile)/File System",
                "\(profile)/Service Worker/Database"
            ]
            passwords += [
                "\(profile)/Login Data",
                "\(profile)/Login Data-journal",
                "\(profile)/Login Data For Account",
                "\(profile)/Web Data",
                "\(profile)/Web Data-journal"
            ]
        }

        // Global Chromium shader/component caches next to profiles
        if fm.fileExists(atPath: supportRoot) {
            cachePaths += [
                "\(supportRoot)/ShaderCache",
                "\(supportRoot)/GrShaderCache",
                "\(supportRoot)/GraphiteDawnCache",
                "\(supportRoot)/component_crx_cache",
                "\(supportRoot)/extensions_crx_cache"
            ]
        }

        // Cookie / 密码库：不进清理列表（PathGate 硬拒；产品不提供清理入口）
        _ = passwords
        return [
            Spec(brand: brand, kind: .cache, paths: cachePaths),
            Spec(brand: brand, kind: .history, paths: history),
            Spec(brand: brand, kind: .downloads, paths: downloads),
            Spec(brand: brand, kind: .siteData, paths: site)
        ]
    }

    private static func chromiumProfiles(in supportRoot: String, fm: FileManager) -> [String] {
        guard fm.fileExists(atPath: supportRoot),
              let names = try? fm.contentsOfDirectory(atPath: supportRoot)
        else { return [] }
        return names
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") || $0 == "Guest Profile" || $0 == "System Profile" }
            .map { "\(supportRoot)/\($0)" }
            .filter { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
    }

    /// Roots claimed by browser scan — exclude from generic userCache listing
    static func userCacheExcludedRoots(home: String) -> [String] {
        [
            "\(home)/Library/Caches/com.apple.Safari",
            "\(home)/Library/Caches/CloudKit/com.apple.Safari",
            "\(home)/Library/Caches/Google/Chrome",
            "\(home)/Library/Caches/Google/Chrome Beta",
            "\(home)/Library/Caches/Microsoft Edge",
            "\(home)/Library/Caches/com.microsoft.edgemac"
        ]
    }

    /// Narrow allow prefixes for scan + trash (beyond generic Caches)
    static func allowedPathPrefixes(home: String) -> [String] {
        [
            "\(home)/Library/Caches/com.apple.Safari",
            "\(home)/Library/Caches/CloudKit/com.apple.Safari",
            "\(home)/Library/Caches/Google/Chrome",
            "\(home)/Library/Caches/Google/Chrome Beta",
            "\(home)/Library/Caches/Microsoft Edge",
            "\(home)/Library/Caches/com.microsoft.edgemac",
            "\(home)/Library/WebKit/com.apple.Safari",
            "\(home)/Library/HTTPStorages/com.apple.Safari",
            "\(home)/Library/Safari",
            // Cookies.binarycookies 不在此列：系统共享 Cookie 罐，禁止经本工具删除
            "\(home)/Library/Application Support/Google/Chrome",
            "\(home)/Library/Application Support/Google/Chrome Beta",
            "\(home)/Library/Application Support/Microsoft Edge",
            "\(home)/Library/Application Support/com.microsoft.edgemac"
        ]
    }
}
