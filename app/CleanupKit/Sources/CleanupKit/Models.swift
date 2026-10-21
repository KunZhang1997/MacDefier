// CleanupKit models + human-readable explainers.
// Scan strategy adapted from PureMac (MIT) © PureMac Contributors.

import Foundation

public enum CleanupCategory: String, CaseIterable, Sendable, Identifiable {
    case userCache
    case systemLogs
    case userLogs
    case trash
    case xcode
    case brew
    case node
    case temp
    case aiApps   // PureMac .aiApps
    case docker   // PureMac .dockerCache
    case installerPackages // DMG / PKG / MPKG, regardless of size
    case largeAppData
    case wallpaper // macOS Aerial resources; active resources are protected
    case orphans  // 已卸 App 留下的 volatile 残留
    case browsers // Safari / Chrome / Edge 分项数据（C08）

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userCache: return "应用缓存"
        case .systemLogs: return "系统日志"
        case .userLogs: return "用户日志"
        case .trash: return "废纸篓"
        case .xcode: return "Xcode 可再生"
        case .brew: return "Homebrew 缓存"
        case .node: return "Node 缓存"
        case .temp: return "临时文件"
        case .aiApps: return "本地 AI 缓存"
        case .docker: return "Docker 缓存"
        case .installerPackages: return "安装包"
        case .largeAppData: return "大文件（按体积）"
        case .wallpaper: return "macOS 壁纸"
        case .orphans: return "卸后孤儿（App / CLI 残留）"
        case .browsers: return "浏览器数据"
        }
    }

    /// 这组是干啥的（白话）
    public var whatIsIt: String {
        switch self {
        case .userCache: return "各 App 为加速下载/解码留下的临时数据"
        case .systemLogs: return "系统写的运行记录，用于排错"
        case .userLogs: return "用户级 App 写的运行记录"
        case .trash: return "你已删除、还在废纸篓里的东西"
        case .xcode: return "Xcode 编译/模拟器产生的可再生文件"
        case .brew: return "Homebrew 下载安装包的缓存"
        case .node: return "npm/yarn/pnpm/pip 下载依赖的缓存"
        case .temp: return "系统或 App 临时目录里的短命文件"
        case .aiApps: return "Ollama / LM Studio 等本地 AI 的日志与缓存（PureMac AI Apps）"
        case .docker: return "Docker Desktop 可再生缓存/日志（非整盘镜像库）"
        case .installerPackages: return "下载或测试留下的 DMG、PKG、MPKG 安装包，不按体积筛选"
        case .largeAppData: return "在下载/文稿/影片等目录里按体积找出的大文件或大文件夹（≥约 100MB），不是固定应用名单"
        case .wallpaper: return "macOS 动态壁纸下载到本机的 Aerial 视频和缩略图；当前使用中的资源不会列出"
        case .orphans: return "本机已无对应 App 或 CLI 程序，但仍留下的缓存/日志/状态，或 CLI 数据目录（如 ~/.kimi）"
        case .browsers: return "Safari、Chrome、Edge 的缓存、浏览记录、Cookie 等（分项勾选，不卸浏览器）"
        }
    }

    /// 清了一般会怎样
    public var ifCleaned: String {
        switch self {
        case .userCache: return "App 可能稍慢一会，会自己重新生成；一般不丢文档/账号"
        case .systemLogs, .userLogs: return "少占空间；以后出问题少一段历史记录可查"
        case .trash: return "从废纸篓彻底清掉，通常更难恢复（不是再移一次废纸篓）"
        case .xcode: return "下次编译/开模拟器会重下或重建，耗时变长"
        case .brew: return "下次 brew 安装可能重新下载"
        case .node: return "下次 install 可能重新下载依赖"
        case .temp: return "一般无感；正在用的程序若依赖该文件可能闪一下"
        case .aiApps: return "模型/对话若勾了可选历史会丢；默认只勾可再生缓存与服务日志"
        case .docker: return "下次 pull/build 可能重建缓存；不删 Docker.app 本身"
        case .installerPackages: return "进废纸篓可还原；确认不再需要安装或测试后再勾选"
        case .largeAppData: return "进废纸篓可还原；可能是你的视频或项目，默认不勾，勾前请确认"
        case .wallpaper: return "只处理未在当前壁纸或轮播设置中使用的资源；以后需要时 macOS 可重新下载"
        case .orphans: return "进废纸篓可还原；仅 volatile 根，不含偏好/容器"
        case .browsers: return "按勾选项处理：缓存可再生；清记录/Cookie 会丢登录态；密码项极高敏"
        }
    }

    public var systemImage: String {
        switch self {
        case .userCache: return "internaldrive"
        case .systemLogs, .userLogs: return "doc.text"
        case .trash: return "trash"
        case .xcode: return "hammer"
        case .brew: return "cup.and.saucer"
        case .node: return "leaf"
        case .temp: return "clock"
        case .aiApps: return "brain"
        case .docker: return "shippingbox"
        case .installerPackages: return "shippingbox"
        case .largeAppData: return "externaldrive"
        case .wallpaper: return "photo.on.rectangle"
        case .orphans: return "shippingbox.and.arrow.backward"
        case .browsers: return "globe"
        }
    }

    public var defaultSelected: Bool {
        // 产品：清理列表一律不自动勾选，由用户自己选
        false
    }
}

/// 能不能放心勾
public enum CleanupRisk: String, Sendable {
    case safe      // 建议可清
    case rebuild   // 可清，会重建
    case caution   // 建议先看清
    case skip      // 默认别勾

    public var label: String {
        switch self {
        case .safe: return "可清"
        case .rebuild: return "可清·会重建"
        case .caution: return "谨慎"
        case .skip: return "建议保留"
        }
    }

    public var tip: String {
        switch self {
        case .safe: return "清了通常没事，进废纸篓可撤销"
        case .rebuild: return "清了会自己长回来，只是下次慢一点"
        case .caution: return "建议确认路径再勾；拿不准就跳过"
        case .skip: return "默认不勾，避免误伤系统或账号相关缓存"
        }
    }
}

public struct CleanableItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let bytes: UInt64
    /// A bounded or interrupted scan measured only part of this item.
    public let sizeIsLowerBound: Bool
    public let category: CleanupCategory
    public var isSelected: Bool
    public let appName: String?
    /// 大体积盘点：所属应用数据根（可选）
    public let parentPath: String?
    /// 列表主标题（人话）
    public let displayTitle: String
    /// 这是啥
    public let whatIsIt: String
    /// 清了会怎样
    public let ifCleaned: String
    public let risk: CleanupRisk
    /// Additional paths trashed with this item (browser multi-path, etc.)
    public let extraPaths: [String]
    /// Derived only from immutable name/path/category/risk, never from selection.
    /// Calculate once, not on every SwiftUI body or bulk-selection pass.
    public private(set) var isLowRiskBulkEligible: Bool = false

    public var allPaths: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in [path] + extraPaths {
            let n = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(n).inserted { out.append(p) }
        }
        return out
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        bytes: UInt64,
        category: CleanupCategory,
        isSelected: Bool,
        appName: String? = nil,
        displayTitle: String? = nil,
        whatIsIt: String? = nil,
        ifCleaned: String? = nil,
        risk: CleanupRisk? = nil,
        parentPath: String? = nil,
        extraPaths: [String] = [],
        sizeIsLowerBound: Bool = false
    ) {
        let explained = ItemExplainer.explain(name: name, path: path, category: category, appName: appName)
        self.id = id
        self.name = name
        self.path = path
        self.bytes = bytes
        self.sizeIsLowerBound = sizeIsLowerBound
        self.category = category
        self.appName = appName
        self.parentPath = parentPath
        self.extraPaths = extraPaths
        self.displayTitle = displayTitle ?? explained.title
        self.whatIsIt = whatIsIt ?? explained.what
        self.ifCleaned = ifCleaned ?? explained.effect
        let baseRisk = risk ?? explained.risk
        let finalRisk = CleanupRiskPolicy.refine(
            name: name,
            path: path,
            category: category,
            base: baseRisk
        )
        self.risk = finalRisk
        // 产品：扫描后一律不自动勾选；仅用户点「勾选低风险」或手动勾
        self.isSelected = false
        self.isLowRiskBulkEligible = CleanupRiskPolicy.isLowRiskBulkEligible(self)
    }

    public var formattedSize: String {
        (sizeIsLowerBound ? "≥ " : "") + ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// Home-relative path for list/AI (`~/Downloads/...`). Outside home returns standardized absolute path.
    public var homeRelativePath: String {
        let home = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
        let n = (path as NSString).standardizingPath
        if n == home { return "~" }
        if n.hasPrefix(home + "/") {
            return "~/" + String(n.dropFirst(home.count + 1))
        }
        return n
    }

    /// Short path identity for list titles when last components collide (e.g. `projA/Downloads` vs `projB/Downloads`).
    public var pathIdentityTitle: String {
        let rel = homeRelativePath
        let trimmed: String
        if rel == "~" {
            trimmed = name
        } else if rel.hasPrefix("~/") {
            trimmed = String(rel.dropFirst(2))
        } else {
            trimmed = rel
        }
        let parts = trimmed.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: "/")
        }
        if let last = parts.last { return last }
        return name
    }
}

public struct CleanupCategoryGroup: Identifiable, Sendable {
    public let id: CleanupCategory
    public var items: [CleanableItem]
    public let isPartial: Bool
    public var category: CleanupCategory { id }

    public var totalBytes: UInt64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public var selectedBytes: UInt64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.bytes }
    }

    public var selectedCount: Int {
        items.filter(\.isSelected).count
    }

    public init(category: CleanupCategory, items: [CleanableItem], isPartial: Bool = false) {
        self.id = category
        self.isPartial = isPartial
        self.items = items
    }
}

public enum CleanupPhase: Equatable, Sendable {
    case idle
    case scanning(progress: Double, hint: String)
    case preview
    case cleaning(progress: Double)
    case done(freed: UInt64, count: Int, errors: [String])
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .scanning, .cleaning: return true
        default: return false
        }
    }
}

public struct CleanupResult: Sendable {
    public var failures: [CleanupFailure] = []
    /// Bytes permanently removed from the volume (currently explicit Trash-category deletes).
    public var freedBytes: UInt64
    /// Bytes moved into Trash. They remain on disk until the user empties Trash.
    public var movedToTrashBytes: UInt64
    public var cleanedCount: Int
    public var errors: [String]
    /// Primary item paths that completed fully. Kept for source compatibility.
    public var trashedPaths: [String]
    /// Every individual source path that was successfully moved/removed.
    public var succeededPaths: [String]
    /// Individual source paths that failed and remain available for retry.
    public var failedPaths: [String]
    /// Main app is still running after a normal 5-second quit attempt.
    public var requiresForceQuit: Bool

    public init(
        freedBytes: UInt64 = 0,
        movedToTrashBytes: UInt64 = 0,
        cleanedCount: Int = 0,
        errors: [String] = [],
        trashedPaths: [String] = [],
        succeededPaths: [String] = [],
        failedPaths: [String] = [],
        requiresForceQuit: Bool = false
    ) {
        self.freedBytes = freedBytes
        self.movedToTrashBytes = movedToTrashBytes
        self.cleanedCount = cleanedCount
        self.errors = errors
        self.trashedPaths = trashedPaths
        self.succeededPaths = succeededPaths
        self.failedPaths = failedPaths
        self.requiresForceQuit = requiresForceQuit
    }
}

// MARK: - Explainer（路径 → 人话）

enum ItemExplainer {
    struct Result {
        var title: String
        var what: String
        var effect: String
        var risk: CleanupRisk
    }

    static func explain(name: String, path: String, category: CleanupCategory, appName: String?) -> Result {
        let lower = (name + " " + path).lowercased()
        let friendly = appName ?? humanizeBundle(name)

        // The scanner's category is stronger evidence than keywords in a temp
        // folder name. Build/test scratch paths such as
        // /tmp/speaksend-ollama-tests are temporary data, not AI/model data.
        if category == .temp {
            return .init(
                title: "临时 · \(friendly)",
                what: "临时目录里的短命文件",
                effect: "可能被正在运行的程序占用；请确认后再勾",
                risk: .caution
            )
        }

        let isKnownLocalModel = lower.contains("/library/application support/speaksend/managedmodels")
            || lower.contains("/.ollama/models")
            || lower.contains("/.lmstudio/models")
            || lower.contains(".gguf")
            || lower.contains("ggml-")

        // 已知模式优先
        if lower.contains("deriveddata") {
            return .init(
                title: "Xcode DerivedData",
                what: "Xcode 编译中间产物（索引、中间目标文件）",
                effect: "清了下次编译变慢并重建；不丢工程源码",
                risk: .rebuild
            )
        }
        if lower.contains("coresimulator") {
            return .init(
                title: "iOS 模拟器缓存",
                what: "模拟器运行时缓存/设备支持文件",
                effect: "清了下次开模拟器可能重下组件",
                risk: .rebuild
            )
        }
        if lower.contains("homebrew") || lower.contains("/brew") || category == .brew {
            return .init(
                title: "Homebrew 下载缓存",
                what: "brew 装软件时下过的安装包缓存",
                effect: "清了下次 brew install/upgrade 可能重新下载",
                risk: .rebuild
            )
        }
        if isKnownLocalModel {
            return .init(
                title: "本地模型文件",
                what: "应用下载到本机的语音/大语言模型文件",
                effect: "清了后相关功能要重新下载模型才能继续用",
                risk: .caution
            )
        }
        if category == .aiApps || lower.contains("ollama") || lower.contains("lmstudio") || lower.contains(".lmstudio") {
            if lower.contains("history") || lower.contains("conversation") {
                return .init(
                    title: friendly,
                    what: "本地 AI 可选历史/对话（PureMac 默认不勾）",
                    effect: "勾了会丢聊天/提示历史",
                    risk: .skip
                )
            }
            return .init(
                title: "本地 AI · \(friendly)",
                what: "Ollama / LM Studio 日志或缓存",
                effect: "可再生；模型权重一般不在这些路径",
                risk: .rebuild
            )
        }
        if lower.contains("com.apple.wallpaper") || lower.contains("aerials") {
            return .init(
                title: "动态壁纸缓存",
                what: "macOS 航拍动态壁纸下载到本机的资源",
                effect: "清了后壁纸可能重新下载；建议先切到静态壁纸再清",
                risk: .rebuild
            )
        }
        if lower.contains("com.netease.mumu.nemux") || lower.contains("/mumu") || lower.contains("nemux") {
            return .init(
                title: "MuMu 模拟器数据",
                what: "MuMu 的实例、镜像包或运行数据",
                effect: "清了可能需要重建或重装模拟器环境；仍在使用时建议先到 MuMu 内清",
                risk: .caution
            )
        }
        if lower.contains("/.colima") || lower.contains("_lima") {
            return .init(
                title: "Colima 虚拟机磁盘",
                what: "Colima 的 Linux VM 磁盘与运行数据",
                effect: "清了基本等于重建 Colima / Docker 环境",
                risk: .caution
            )
        }
        if category == .docker || lower.contains("docker") || lower.contains("buildx") {
            return .init(
                title: "Docker · \(friendly)",
                what: "Docker Desktop 可再生缓存/日志（非镜像层整库）",
                effect: "清了下次构建/拉取可能变慢",
                risk: .rebuild
            )
        }
        if lower.contains("npm") || lower.contains("_cacache") {
            return .init(
                title: "npm 包缓存",
                what: "Node 包管理器下过的依赖包",
                effect: "清了下次 npm install 会重新下",
                risk: .rebuild
            )
        }
        if lower.contains("yarn") || lower.contains("pnpm") || lower.contains("pip") {
            return .init(
                title: "开发依赖缓存",
                what: "前端/Python 包管理器缓存",
                effect: "清了下次安装依赖会重新下载",
                risk: .rebuild
            )
        }
        if lower.contains(".trash") || path.contains("/.Trash/") {
            return .init(
                title: friendly,
                what: "已在废纸篓里的文件/文件夹",
                effect: "勾选清理 = 清空该项（永久删除，通常更难恢复；与缓存「移入废纸篓」不同）",
                risk: .caution
            )
        }

        // PureMac 用户缓存扫描不按 com.apple.* 默认反选；人话保留，风险跟可重建
        if name.hasPrefix("com.apple.") || lower.contains("com.apple.") {
            return .init(
                title: "系统相关 · \(friendly)",
                what: "名称像系统组件（com.apple.*）的缓存（PureMac 同样扫入用户缓存）",
                effect: "多数可重建；短时可能影响对应系统服务",
                risk: .rebuild
            )
        }
        // 仅名称强暗示凭证时保守（PureMac 无此层；保留最小保护）
        if lower.contains("keychain") || lower.contains("password") {
            return .init(
                title: friendly,
                what: "名称像钥匙串/密码相关",
                effect: "可能影响登录态；建议保留",
                risk: .skip
            )
        }
        if lower.contains("chrome") || lower.contains("firefox") || lower.contains("edge") || lower.contains("safari") {
            return .init(
                title: "浏览器 · \(friendly)",
                what: "浏览器缓存（网页图片/脚本等）",
                effect: "网页首次打开变慢；一般不丢书签（书签不在 Caches）",
                risk: .rebuild
            )
        }
        if lower.contains("slack") || lower.contains("discord") || lower.contains("telegram")
            || lower.contains("wechat") || lower.contains("whatsapp") {
            return .init(
                title: "聊天应用 · \(friendly)",
                what: "即时通讯类缓存（缩略图、媒体缓存等）",
                effect: "媒体可能重下；聊天记录通常不在 Caches 主目录",
                risk: .caution // 仍可能在用，不进一键低风险
            )
        }
        if lower.contains("colima") || lower.contains("swiftpm") || lower == "geoservices" {
            return .init(
                title: "开发/系统 · \(friendly)",
                what: "开发工具或系统相关缓存，多半仍在用",
                effect: "清了可能要重建环境或暂时影响服务",
                risk: .caution
            )
        }
        if category == .userLogs || category == .systemLogs {
            return .init(
                title: "日志 · \(friendly)",
                what: "程序运行记录，方便排查故障",
                effect: "腾出空间；以后查历史问题少材料",
                risk: .safe
            )
        }
        if category == .userCache {
            return .init(
                title: "缓存 · \(friendly)",
                what: "「\(friendly)」应用的缓存文件夹（加速用）",
                effect: "App 会自己再生成；仍在用的工具请勿当低风险一键勾",
                risk: .rebuild
            )
        }

        return .init(
            title: friendly,
            what: category.whatIsIt,
            effect: category.ifCleaned,
            risk: .caution
        )
    }

    private static func humanizeBundle(_ name: String) -> String {
        if name.hasPrefix("com.") || name.hasPrefix("org.") || name.hasPrefix("net.") || name.hasPrefix("io.") {
            let parts = name.split(separator: ".")
            if let last = parts.last { return String(last) }
        }
        return name
    }
}
