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
        let detail: String
        let profile: String?
        let paths: [String]
    }

    static func specs(home: String, fm: FileManager) -> [Spec] {
        var out: [Spec] = []
        func add(_ brand: BrowserBrand, _ kind: BrowserDataKind, _ detail: String,
                 _ profile: String? = nil, _ paths: [String]) {
            out.append(Spec(brand: brand, kind: kind, detail: detail, profile: profile, paths: paths))
        }
        add(.safari, .cache, "webCache", nil, ["\(home)/Library/Caches/com.apple.Safari"])
        add(.safari, .siteData, "browserStorage", nil, ["\(home)/Library/WebKit/com.apple.Safari"])
        add(.safari, .siteData, "browserStorage", nil, ["\(home)/Library/HTTPStorages/com.apple.Safari"])
        add(.safari, .history, "history", nil, ["\(home)/Library/Safari/History.db", "\(home)/Library/Safari/History.db-wal", "\(home)/Library/Safari/History.db-shm"])
        add(.safari, .history, "historyIndex", nil, ["\(home)/Library/Safari/HistoryIndex.sk"])
        add(.safari, .history, "recentTabs", nil, ["\(home)/Library/Safari/RecentlyClosedTabs.plist"])
        add(.safari, .history, "topSites", nil, ["\(home)/Library/Safari/TopSites.db"])
        add(.safari, .history, "lastSession", nil, ["\(home)/Library/Safari/LastSession.plist"])
        add(.safari, .downloads, "downloads", nil, ["\(home)/Library/Safari/Downloads.plist"])
        for leaf in ["LocalStorage", "Databases", "IndexedDB"] {
            add(.safari, .siteData, "siteStorage", nil, ["\(home)/Library/Safari/\(leaf)"])
        }
        let browsers: [(BrowserBrand, String, [String])] = [
            (.chrome, "\(home)/Library/Application Support/Google/Chrome", ["\(home)/Library/Caches/Google/Chrome"]),
            (.edge, "\(home)/Library/Application Support/Microsoft Edge", ["\(home)/Library/Caches/Microsoft Edge", "\(home)/Library/Caches/com.microsoft.edgemac"]),
            (.edge, "\(home)/Library/Application Support/com.microsoft.edgemac", [])
        ]
        for (brand, supportRoot, cacheRoots) in browsers {
            let profileNames: (String) -> [String] = { root in
                (try? fm.contentsOfDirectory(atPath: root))?.filter {
                    $0 == "Default" || $0.hasPrefix("Profile ") || $0 == "Guest Profile" || $0 == "System Profile"
                }.sorted() ?? []
            }
            for root in cacheRoots {
                for profile in profileNames(root) {
                    let base = "\(root)/\(profile)"
                    for (leaf, detail) in [("Cache", "webCache"), ("Code Cache", "codeCache"), ("image_cache", "imageCache"), ("GPUCache", "graphicsCache")] {
                        add(brand, .cache, detail, profile, ["\(base)/\(leaf)"])
                    }
                    add(brand, .siteData, "browserStorage", profile, ["\(base)/Storage"])
                }
            }
            for profile in profileNames(supportRoot) {
                let base = "\(supportRoot)/\(profile)"
                for (leaf, detail) in [("Cache", "webCache"), ("Code Cache", "codeCache"), ("GPUCache", "graphicsCache"), ("DawnCache", "graphicsCache"), ("DawnGraphiteCache", "graphicsCache"), ("DawnWebGPUCache", "graphicsCache"), ("GrShaderCache", "graphicsCache"), ("ShaderCache", "graphicsCache")] {
                    add(brand, .cache, detail, profile, ["\(base)/\(leaf)"])
                }
                // CacheStorage contains website/extension offline data, not just disposable HTTP cache.
                add(brand, .siteData, "serviceWorkerStorage", profile, ["\(base)/Service Worker/CacheStorage"])
                add(brand, .history, "history", profile, ["\(base)/History", "\(base)/History-journal", "\(base)/History-wal", "\(base)/History-shm"])
                add(brand, .history, "visitedLinks", profile, ["\(base)/Visited Links"])
                add(brand, .history, "topSites", profile, ["\(base)/Top Sites", "\(base)/Top Sites-journal", "\(base)/Top Sites-wal", "\(base)/Top Sites-shm"])
                for leaf in ["DownloadMetadata", "Download Service"] {
                    add(brand, .downloads, "downloads", profile, ["\(base)/\(leaf)"])
                }
                for leaf in ["Local Storage", "Session Storage", "IndexedDB", "File System", "Service Worker/Database"] {
                    add(brand, .siteData, "siteStorage", profile, ["\(base)/\(leaf)"])
                }
            }
            for leaf in ["ShaderCache", "GrShaderCache", "GraphiteDawnCache", "component_crx_cache", "extensions_crx_cache"] {
                add(brand, .cache, leaf.contains("cache") ? "componentCache" : "graphicsCache", nil, ["\(supportRoot)/\(leaf)"])
            }
        }
        // Cookie and credential databases never become cleanup candidates.
        return out
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
