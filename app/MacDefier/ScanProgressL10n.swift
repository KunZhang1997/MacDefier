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
            if geometry.size.width >= 880 {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView { VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { stage in step(stage, horizontal: false) }
                    }.padding(16) }
                    .frame(width: 190)
                    content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(rows) { stage in step(stage, horizontal: true).id(stage.id) }
                            }.padding(.horizontal, MDTheme.pagePadding).padding(.vertical, 10)
                        }
                        .onChange(of: journey.activeID) { _, id in
                            guard let id else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { reader.scrollTo(id, anchor: .center) }
                        }
                    }
                    content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func step(_ stage: ScanJourney.Stage, horizontal: Bool) -> some View {
        let active = journey.activeID == stage.id && journey.status == .running
        let state = stage.completed ? (stage.partial ? "partial" : "done") : active ? "reading" : "waiting"
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if active && !reduceMotion { ProgressView().controlSize(.small) }
                else { Image(systemName: stage.completed ? (stage.partial ? "exclamationmark.circle" : "checkmark.circle.fill") : active ? "viewfinder" : "circle") }
            }
            .foregroundStyle(active ? MDTheme.accent : MDTheme.secondary)
            .frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(ScanProgressL10n.localize(stage.id)).font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? MDTheme.label : MDTheme.secondary)
                Text(stage.count.map { L10n.t("scan.stage_count", $0) } ?? L10n.t("scan.state." + state))
                    .font(.caption).foregroundStyle(MDTheme.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, horizontal ? 3 : 10)
        .frame(minWidth: horizontal ? 120 : 0, maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ScanProgressL10n.localize(stage.id)), \(L10n.t("scan.state." + state))\(stage.count.map { ", " + L10n.t("scan.stage_count", $0) } ?? "")")
        .accessibilityIdentifier("scan.step." + stage.id)
    }
}
