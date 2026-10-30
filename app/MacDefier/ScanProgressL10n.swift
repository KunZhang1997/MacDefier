// Maps CleanupKit progress tokens (category rawValue / machine keys) → UI language.

import Foundation
import CleanupKit
import SwiftUI

enum ScanProgressL10n {
    /// JunkScanner now emits category `rawValue` or `"done"`.
    /// Older builds may still emit Chinese titles — map those too.
    static func localize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if t.hasPrefix("scan.stage.") { return L10n.t(t) }
        if let separator = t.firstIndex(of: "|") {
            let category = String(t[..<separator])
            let detail = String(t[t.index(after: separator)...])
            let label = detail.hasPrefix("scan.") ? localize(detail) : detail
            return localize(category) + " · " + label
        }

        switch t {
        case "scan.waiting", "scan.cli_inventory", "scan.app_inventory":
            return L10n.t(t)
        case "done", "完成":
            return L10n.t("common.done")
        case "preparing", "准备…", "准备":
            return L10n.t("common.preparing")
        case "scan.other_busy", "另一个扫描进行中":
            return L10n.t("diag.scan_other_busy")
        case "ai_review", "AI 盘点…", "AI 盘点":
            return L10n.t("cleanup.ai_busy")
        default:
            break
        }

        // Prefer category key: cleanup.cat.temp → Temp files
        if let cat = CleanupCategory(rawValue: t) {
            return cat.localizedTitle
        }
        let key = "cleanup.cat.\(t)"
        let viaKey = L10n.t(key)
        if viaKey != key { return viaKey }

        // Legacy Chinese titles from kit
        let legacy: [String: String] = [
            "应用缓存": "userCache",
            "系统日志": "systemLogs",
            "用户日志": "userLogs",
            "废纸篓": "trash",
            "Xcode 可再生": "xcode",
            "Homebrew 缓存": "brew",
            "Node 缓存": "node",
            "临时文件": "temp",
            "本地 AI 缓存": "aiApps",
            "Docker 缓存": "docker",
            "大体积应用数据": "largeAppData",
            "卸后孤儿（已删 App 的残留）": "orphans",
            "浏览器数据": "browsers"
        ]
        if let rawKey = legacy[t], let cat = CleanupCategory(rawValue: rawKey) {
            return cat.localizedTitle
        }
        return t
    }

    /// "Temp files · Stop anytime"
    static func withStop(_ phase: String) -> String {
        let p = localize(phase)
        if p.isEmpty { return L10n.t("chat.status.stop_only") }
        return L10n.t("chat.status.phase_stop", p)
    }
}

/// Same interaction grammar on all four pages, driven by scanner-owned evidence.
struct MDScanWorkbench<Content: View>: View {
    let journey: ScanJourney
    let stages: [String]
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [ScanJourney.Stage] {
        journey.stages.isEmpty ? ScanJourney(stages: stages).stages : journey.stages
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rows) { stage in
                                step(stage, horizontal: false).id(stage.id)
                            }
                        }
                        .padding(geometry.size.width < 880 ? 8 : 16)
                    }
                    .onChange(of: journey.activeID) { _, id in
                        guard let id else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            reader.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .frame(width: geometry.size.width < 880 ? 150 : 190)
                content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Category symbols describe the work; small badges report only real scanner state.
    private func stageSymbol(_ id: String) -> String {
        switch id.replacingOccurrences(of: "scan.stage.", with: "") {
        case "userCache", "appData": return "shippingbox"
        case "userLogs", "systemLogs": return "doc.text"
        case "browsers": return "safari"
        case "xcode": return "hammer"
        case "brew", "npm", "node", "uv", "cliData", "manual": return "terminal"
        case "aiApps", "models": return "cpu"
        case "docker": return "cube.box"
        case "wallpaper": return "photo"
        case "installerPackages": return "shippingbox.fill"
        case "largeAppData", "file_metadata": return "folder"
        case "orphans": return "doc.badge.gearshape"
        case "temp": return "clock"
        case "trash": return "trash"
        case "conversations": return "bubble.left.and.bubble.right"
        case "worktrees": return "arrow.triangle.branch"
        case "apps": return "square.grid.2x2"
        case "app_sizes", "space_map": return "internaldrive"
        case "verify": return "checkmark.shield"
        default: return "doc"
        }
    }

    private func step(_ stage: ScanJourney.Stage, horizontal: Bool) -> some View {
        let active = journey.activeID == stage.id && journey.status == .running
        let state = stage.completed ? (stage.partial ? "partial" : "done") : active ? "reading" : "waiting"
        return HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? MDTheme.surface : MDTheme.surfaceInset)
                Image(systemName: stageSymbol(stage.id))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? MDTheme.label : MDTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if stage.completed {
                    Image(systemName: stage.partial ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(stage.partial ? MDTheme.warning : MDTheme.secondary)
                        .background(MDTheme.content, in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(ScanProgressL10n.localize(stage.id))
                    .font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(active || journey.status == .idle ? MDTheme.label : MDTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if active {
                    HStack(spacing: 4) {
                        Text(L10n.t("scan.state.reading"))
                        activityDots
                    }
                    .font(.caption).foregroundStyle(MDTheme.secondary)
                } else if let count = stage.count, stage.completed {
                    Text(L10n.t("scan.stage_count", count))
                        .font(.caption).foregroundStyle(MDTheme.secondary).monospacedDigit()
                } else if stage.partial && stage.completed {
                    Text(L10n.t("scan.state.partial"))
                        .font(.caption).foregroundStyle(MDTheme.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, horizontal ? 6 : 7)
        .frame(minWidth: horizontal ? 120 : 0, maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        .background(active ? MDTheme.surfaceInset : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ScanProgressL10n.localize(stage.id) +
            ", \(L10n.t("scan.state." + state))\(stage.count.map { ", " + L10n.t("scan.stage_count", $0) } ?? "")")
        .accessibilityIdentifier("scan.step." + stage.id)
    }

    @ViewBuilder private var activityDots: some View {
        if reduceMotion {
            Text("···").accessibilityHidden(true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.24)) { timeline in
                let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.24) % 3
                HStack(spacing: 2) {
                    ForEach(0..<3) { index in
                        Circle().fill(MDTheme.secondary.opacity(index == phase ? 0.9 : 0.25))
                            .frame(width: 3, height: 3)
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}
