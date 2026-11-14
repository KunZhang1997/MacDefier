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
        if let kind = browserKind, let detail = browserDetail {
            let parts = [appName ?? "Browser", L10n.t("cleanup.browser.kind." + kind.rawValue), browserProfile, L10n.t("cleanup.browser.detail." + detail)].compactMap { $0 }
            return parts.joined(separator: " · ")
        }
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
        if let kind = browserKind { return L10n.t("cleanup.browser.what." + kind.rawValue) }
        if category == .installerPackages {
            return category.localizedWhatIsIt
        }
        if category == .largeAppData {
            let rel = homeRelativePath
            let key = isDirectory ? "cleanup.large_item.folder.what" : "cleanup.large_item.file.what"
            return L10n.t(key, rel)
        }
        return CleanupItemL10n.explain(name: name, path: path, category: category, appName: appName).what
    }

    var localizedIfCleaned: String {
        if ifCleaned.hasPrefix("cleanup_blocked:") {
            return L10n.t("cleanup.reason." + ifCleaned.dropFirst("cleanup_blocked:".count))
        }
        if let kind = browserKind { return L10n.t("cleanup.browser.effect." + kind.rawValue) }
        if ifCleaned.hasPrefix("ai_cleanup:") {
            return L10n.t("aitools.reason." + ifCleaned.dropFirst("ai_cleanup:".count))
        }
        return CleanupItemL10n.explain(name: name, path: path, category: category, appName: appName).effect
    }

    /// e.g. `Downloads/aps-frontend` — drives shipped `CleanableItem.pathIdentityTitle`.
    private var largeFileDisplayTitle: String {
        pathIdentityTitle
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
        let friendly = appName ?? ItemExplainer.humanizeBundle(name)
        switch ItemExplainer.classify(name: name, path: path, category: category) {
        case .temp:
            return .init(
                title: L10n.t("cleanup.item.temp", friendly),
                what: L10n.t("cleanup.item.temp.what"),
                effect: L10n.t("cleanup.item.temp.if")
            )
        case .derivedData:
            return .init(
                title: L10n.t("cleanup.item.deriveddata"),
                what: L10n.t("cleanup.item.deriveddata.what"),
                effect: L10n.t("cleanup.item.deriveddata.if")
            )
        case .coreSimulator:
            return .init(
                title: L10n.t("cleanup.item.sim"),
                what: L10n.t("cleanup.item.sim.what"),
                effect: L10n.t("cleanup.item.sim.if")
            )
        case .homebrew:
            return .init(
                title: L10n.t("cleanup.item.brew"),
                what: L10n.t("cleanup.item.brew.what"),
                effect: L10n.t("cleanup.item.brew.if")
            )
        case .localModel:
            return .init(
                title: L10n.t("cleanup.item.models"),
                what: L10n.t("cleanup.item.models.what"),
                effect: L10n.t("cleanup.item.models.if")
            )
        case .aiHistory:
            return .init(
                title: friendly,
                what: L10n.t("cleanup.item.ai_history.what"),
                effect: L10n.t("cleanup.item.ai_history.if")
            )
        case .aiCacheOrLog:
            return .init(
                title: L10n.t("cleanup.item.ai", friendly),
                what: L10n.t("cleanup.item.ai.what"),
                effect: L10n.t("cleanup.item.ai.if")
            )
        case .wallpaper:
            return .init(
                title: L10n.t("cleanup.item.wallpaper"),
                what: L10n.t("cleanup.item.wallpaper.what"),
                effect: L10n.t("cleanup.item.wallpaper.if")
            )
        case .mumuSimulator:
            return .init(
                title: L10n.t("cleanup.item.mumu"),
                what: L10n.t("cleanup.item.mumu.what"),
                effect: L10n.t("cleanup.item.mumu.if")
            )
        case .colimaVM:
            return .init(
                title: L10n.t("cleanup.item.colima"),
                what: L10n.t("cleanup.item.colima.what"),
                effect: L10n.t("cleanup.item.colima.if")
            )
        case .docker:
            return .init(
                title: L10n.t("cleanup.item.docker", friendly),
                what: L10n.t("cleanup.item.docker.what"),
                effect: L10n.t("cleanup.item.docker.if")
            )
        case .devDependencyCache:
            return .init(
                title: L10n.t("cleanup.item.devdep"),
                what: L10n.t("cleanup.item.devdep.what"),
                effect: L10n.t("cleanup.item.devdep.if")
            )
        case .npmCache:
            return .init(
                title: L10n.t("cleanup.item.npm"),
                what: L10n.t("cleanup.item.npm.what"),
                effect: L10n.t("cleanup.item.npm.if")
            )
        case .trash:
            return .init(
                title: friendly,
                what: L10n.t("cleanup.item.trash.what"),
                effect: L10n.t("cleanup.item.trash.if")
            )
        case .appleSystemCache:
            return .init(
                title: L10n.t("cleanup.item.system", friendly),
                what: L10n.t("cleanup.item.system.what"),
                effect: L10n.t("cleanup.item.system.if")
            )
        case .secrets:
            return .init(
                title: friendly,
                what: L10n.t("cleanup.item.secrets.what"),
                effect: L10n.t("cleanup.item.secrets.if")
            )
        case .browser:
            return .init(
                title: L10n.t("cleanup.item.browser", friendly),
                what: L10n.t("cleanup.item.browser.what"),
                effect: L10n.t("cleanup.item.browser.if")
            )
        case .chatApp:
            return .init(
                title: L10n.t("cleanup.item.chat", friendly),
                what: L10n.t("cleanup.item.chat.what"),
                effect: L10n.t("cleanup.item.chat.if")
            )
        case .devOrSystemTool:
            return .init(
                title: L10n.t("cleanup.item.devsys", friendly),
                what: L10n.t("cleanup.item.devsys.what"),
                effect: L10n.t("cleanup.item.devsys.if")
            )
        case .log:
            return .init(
                title: L10n.t("cleanup.item.log", friendly),
                what: L10n.t("cleanup.item.log.what"),
                effect: L10n.t("cleanup.item.log.if")
            )
        case .userCache:
            return .init(
                title: L10n.t("cleanup.item.cache", friendly),
                what: L10n.t("cleanup.item.cache.what", friendly),
                effect: L10n.t("cleanup.item.cache.if")
            )
        case .categoryDefault:
            return .init(
                title: friendly,
                what: category.localizedWhatIsIt,
                effect: category.localizedIfCleaned
            )
        }
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
