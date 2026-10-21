// LocalizedCatalog — UI strings for CleanupKit / MonitorKit enums.
// Kit keeps Chinese raw for logs/AI dumps; App UI always goes through L10n.

import CleanupKit
import Foundation
import MonitorKit

// MARK: - Cleanup category

extension CleanupCategory {
    var localizedTitle: String {
        L10n.t("cleanup.cat.\(rawValue)")
    }

    var localizedWhatIsIt: String {
        L10n.t("cleanup.cat.\(rawValue).what")
    }

    var localizedIfCleaned: String {
        L10n.t("cleanup.cat.\(rawValue).if")
    }
}

// MARK: - Risk

extension CleanupRisk {
    var localizedLabel: String {
        L10n.t("cleanup.risk.\(rawValue)")
    }

    var localizedTip: String {
        L10n.t("cleanup.risk.\(rawValue).tip")
    }
}

// MARK: - Cleanable item (re-explain for UI language)

extension CleanableItem {
    /// List title in current app language (not kit Chinese).
    /// Large files: keep path identity (last 1–2 path components) so many "Downloads" stay distinguishable.
    var localizedDisplayTitle: String {
        if category == .largeAppData || category == .installerPackages {
            return largeFileDisplayTitle
        }
        // CleanupKit stores fallback explanations in Chinese. Temp/AI items
        // must always be re-explained in the currently selected UI language.
        if category == .temp || category == .aiApps {
            return CleanupItemL10n.explain(name: name, path: path, category: category, appName: appName).title
        }
        // Prefer scanner-provided title when it carries more than bare last component.
        let kit = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !kit.isEmpty, kit != name, kit.count > name.count {
            return kit
        }
        return CleanupItemL10n.explain(name: name, path: path, category: category, appName: appName).title
    }

    var localizedWhatIsIt: String {
        if category == .installerPackages {
            return category.localizedWhatIsIt
        }
        if category == .largeAppData {
            let rel = homeRelativePath
            let kind = pathIsDirectoryHint ? (AppLanguage.current.isEnglish ? "folder" : "文件夹") : (AppLanguage.current.isEnglish ? "file" : "文件")
            if AppLanguage.current.isEnglish {
                return "Large \(kind) by size (≥~100MB). \(rel)"
            }
            return "按体积发现的大\(kind)（≥约 100MB）。\(rel)"
        }
        return CleanupItemL10n.explain(name: name, path: path, category: category, appName: appName).what
    }

    var localizedIfCleaned: String {
        if ifCleaned.hasPrefix("cleanup_blocked:") {
            return L10n.t("cleanup.reason." + ifCleaned.dropFirst("cleanup_blocked:".count))
        }
        if ifCleaned.hasPrefix("ai_cleanup:") {
            return L10n.t("aitools.reason." + ifCleaned.dropFirst("ai_cleanup:".count))
        }
        return CleanupItemL10n.explain(name: name, path: path, category: category, appName: appName).effect
    }

    /// e.g. `Downloads/aps-frontend` — drives shipped `CleanableItem.pathIdentityTitle`.
    private var largeFileDisplayTitle: String {
        pathIdentityTitle
    }

    private var pathIsDirectoryHint: Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}

/// Mirrors CleanupKit `ItemExplainer` patterns with L10n keys.
enum CleanupItemL10n {
    struct Result {
        var title: String
        var what: String
        var effect: String
    }

    static func explain(name: String, path: String, category: CleanupCategory, appName: String?) -> Result {
        let lower = (name + " " + path).lowercased()
        let friendly = appName ?? humanizeBundle(name)

        // Category beats incidental product keywords in temp build/test names.
        if category == .temp {
            return .init(
                title: L10n.t("cleanup.item.temp", friendly),
                what: L10n.t("cleanup.item.temp.what"),
                effect: L10n.t("cleanup.item.temp.if")
            )
        }

        let isKnownLocalModel = lower.contains("/library/application support/speaksend/managedmodels")
            || lower.contains("/.ollama/models")
            || lower.contains("/.lmstudio/models")
            || lower.contains(".gguf")
            || lower.contains("ggml-")

        if lower.contains("deriveddata") {
            return .init(
                title: L10n.t("cleanup.item.deriveddata"),
                what: L10n.t("cleanup.item.deriveddata.what"),
                effect: L10n.t("cleanup.item.deriveddata.if")
            )
        }
        if lower.contains("coresimulator") {
            return .init(
                title: L10n.t("cleanup.item.sim"),
                what: L10n.t("cleanup.item.sim.what"),
                effect: L10n.t("cleanup.item.sim.if")
            )
        }
        if lower.contains("homebrew") || lower.contains("/brew") || category == .brew {
            return .init(
                title: L10n.t("cleanup.item.brew"),
                what: L10n.t("cleanup.item.brew.what"),
                effect: L10n.t("cleanup.item.brew.if")
            )
        }
        if isKnownLocalModel {
            return .init(
                title: L10n.t("cleanup.item.models"),
                what: L10n.t("cleanup.item.models.what"),
                effect: L10n.t("cleanup.item.models.if")
            )
        }
        if category == .aiApps || lower.contains("ollama") || lower.contains("lmstudio") || lower.contains(".lmstudio") {
            if lower.contains("history") || lower.contains("conversation") {
                return .init(
                    title: friendly,
                    what: L10n.t("cleanup.item.ai_history.what"),
                    effect: L10n.t("cleanup.item.ai_history.if")
                )
            }
            return .init(
                title: L10n.t("cleanup.item.ai", friendly),
                what: L10n.t("cleanup.item.ai.what"),
                effect: L10n.t("cleanup.item.ai.if")
            )
        }
        if lower.contains("com.apple.wallpaper") || lower.contains("aerials") {
            return .init(
                title: L10n.t("cleanup.item.wallpaper"),
                what: L10n.t("cleanup.item.wallpaper.what"),
                effect: L10n.t("cleanup.item.wallpaper.if")
            )
        }
        if lower.contains("com.netease.mumu.nemux") || lower.contains("/mumu") || lower.contains("nemux") {
            return .init(
                title: L10n.t("cleanup.item.mumu"),
                what: L10n.t("cleanup.item.mumu.what"),
                effect: L10n.t("cleanup.item.mumu.if")
            )
        }
        if lower.contains("/.colima") || lower.contains("_lima") {
            return .init(
                title: L10n.t("cleanup.item.colima"),
                what: L10n.t("cleanup.item.colima.what"),
                effect: L10n.t("cleanup.item.colima.if")
            )
        }
        if category == .docker || lower.contains("docker") || lower.contains("buildx") {
            return .init(
                title: L10n.t("cleanup.item.docker", friendly),
                what: L10n.t("cleanup.item.docker.what"),
                effect: L10n.t("cleanup.item.docker.if")
            )
        }
        if lower.contains("npm") || lower.contains("_cacache") {
            return .init(
                title: L10n.t("cleanup.item.npm"),
                what: L10n.t("cleanup.item.npm.what"),
                effect: L10n.t("cleanup.item.npm.if")
            )
        }
        if lower.contains("yarn") || lower.contains("pnpm") || lower.contains("pip") {
            return .init(
                title: L10n.t("cleanup.item.devdep"),
                what: L10n.t("cleanup.item.devdep.what"),
                effect: L10n.t("cleanup.item.devdep.if")
            )
        }
        if lower.contains(".trash") || path.contains("/.Trash/") {
            return .init(
                title: friendly,
                what: L10n.t("cleanup.item.trash.what"),
                effect: L10n.t("cleanup.item.trash.if")
            )
        }
        if name.hasPrefix("com.apple.") || lower.contains("com.apple.") {
            return .init(
                title: L10n.t("cleanup.item.system", friendly),
                what: L10n.t("cleanup.item.system.what"),
                effect: L10n.t("cleanup.item.system.if")
            )
        }
        if lower.contains("keychain") || lower.contains("password") {
            return .init(
                title: friendly,
                what: L10n.t("cleanup.item.secrets.what"),
                effect: L10n.t("cleanup.item.secrets.if")
            )
        }
        if lower.contains("chrome") || lower.contains("firefox") || lower.contains("edge") || lower.contains("safari") {
            return .init(
                title: L10n.t("cleanup.item.browser", friendly),
                what: L10n.t("cleanup.item.browser.what"),
                effect: L10n.t("cleanup.item.browser.if")
            )
        }
        if lower.contains("slack") || lower.contains("discord") || lower.contains("telegram")
            || lower.contains("wechat") || lower.contains("whatsapp") {
            return .init(
                title: L10n.t("cleanup.item.chat", friendly),
                what: L10n.t("cleanup.item.chat.what"),
                effect: L10n.t("cleanup.item.chat.if")
            )
        }
        if lower.contains("colima") || lower.contains("swiftpm") || lower == "geoservices" {
            return .init(
                title: L10n.t("cleanup.item.devsys", friendly),
                what: L10n.t("cleanup.item.devsys.what"),
                effect: L10n.t("cleanup.item.devsys.if")
            )
        }
        if category == .userLogs || category == .systemLogs {
            return .init(
                title: L10n.t("cleanup.item.log", friendly),
                what: L10n.t("cleanup.item.log.what"),
                effect: L10n.t("cleanup.item.log.if")
            )
        }
        if category == .userCache {
            return .init(
                title: L10n.t("cleanup.item.cache", friendly),
                what: L10n.t("cleanup.item.cache.what", friendly),
                effect: L10n.t("cleanup.item.cache.if")
            )
        }
        return .init(
            title: friendly,
            what: category.localizedWhatIsIt,
            effect: category.localizedIfCleaned
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

// MARK: - Software

extension SoftwareSizeTier {
    var localizedTitle: String {
        L10n.t("software.tier.\(rawValue)")
    }

    var localizedSubtitle: String {
        L10n.t("software.tier.\(rawValue).sub")
    }
}

extension SoftwareSort {
    var localizedTitle: String {
        switch self {
        case .sizeDesc: return L10n.t("software.sort.size")
        case .nameAsc: return L10n.t("software.sort.name")
        }
    }
}

extension SoftwareListKind {
    var localizedTitle: String {
        switch self {
        case .apps: return L10n.t("software.tab.apps")
        case .cli: return L10n.t("software.tab.cli")
        }
    }
}

extension CliToolChannel {
    var localizedTitle: String {
        switch self {
        case .npm: return L10n.t("software.cli.channel.npm")
        case .brew: return L10n.t("software.cli.channel.brew")
        case .uv: return L10n.t("software.cli.channel.uv")
        case .manual: return L10n.t("software.cli.channel.manual")
        case .unknown: return L10n.t("software.cli.channel.unknown")
        }
    }
}

extension ResidualKind {
    var localizedTitle: String {
        switch self {
        case .appBundle: return L10n.t("residual.kind.app")
        case .cache: return L10n.t("residual.kind.cache")
        case .logs: return L10n.t("residual.kind.logs")
        case .support: return L10n.t("residual.kind.support")
        case .preferences: return L10n.t("residual.kind.prefs")
        case .savedState: return L10n.t("residual.kind.saved")
        case .containers: return L10n.t("residual.kind.containers")
        case .mediaLibrary: return L10n.t("residual.kind.media")
        case .other: return L10n.t("residual.kind.other")
        }
    }
}

// MARK: - Disk role (MonitorKit)

extension DiskVolumeKind {
    var localizedTitle: String {
        switch self {
        case .system: return L10n.t("disk.kind.system")
        case .internalVol: return L10n.t("disk.kind.internal")
        case .external: return L10n.t("disk.kind.external")
        case .network: return L10n.t("disk.kind.network")
        case .diskImage: return L10n.t("disk.kind.image")
        case .other: return L10n.t("disk.kind.other")
        }
    }
}

extension DiskVolume {
    var localizedKindLabel: String { kind.localizedTitle }
}
