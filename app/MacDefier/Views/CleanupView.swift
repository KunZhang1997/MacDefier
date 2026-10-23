import SwiftUI
import CleanupKit
import AppKit

struct CleanupView: View {
    @StateObject private var cleanup = CleanupService.shared
    @StateObject private var scanAnimation = MDScanAnimationClock()
    @ObservedObject private var nav = AppNavigator.shared
    @State private var confirmTrash = false
    @State private var expanded: Set<CleanupCategory> = []
    @State private var expandedItemPaths: Set<String> = []
    @State private var itemDisplayLimits: [CleanupCategory: Int] = [:]
    @State private var aiSettings = AISettingsStore.load()
    @State private var showAIReview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private static let initialItemLimit = 40
    private static let itemPageSize = 40

    /// One identity and one root view per lazy row, including expanded categories.
    /// Nested variable-count Groups make the lazy layout remeasure entire sections.
    private enum PreviewRow: Identifiable {
        case header(CleanupCategoryGroup)
        case caution(CleanupCategoryGroup)
        case item(CleanupCategory, CleanableItem, last: Bool, separator: Bool)
        case more(CleanupCategory, remaining: Int, limit: Int)

        var id: String {
            switch self {
            case .header(let group): return "header:\(group.category.rawValue)"
            case .caution(let group): return "caution:\(group.category.rawValue)"
            case .item(let category, let item, _, _): return "item:\(category.rawValue):\(item.id)"
            case .more(let category, _, _): return "more:\(category.rawValue)"
            }
        }
    }

    private var previewRows: [PreviewRow] {
        var rows: [PreviewRow] = []
        for group in cleanup.groups {
            rows.append(.header(group))
            guard expanded.contains(group.category) else { continue }
            let limit = itemDisplayLimits[group.category] ?? Self.initialItemLimit
            let items = Array(group.items.prefix(limit))
            if needsCaution(group.category) { rows.append(.caution(group)) }
            for (index, item) in items.enumerated() {
                rows.append(.item(group.category, item,
                                  last: index == group.items.count - 1,
                                  separator: index < items.count - 1))
            }
            if items.count < group.items.count {
                rows.append(.more(group.category, remaining: group.items.count - items.count, limit: limit))
            }
        }
        return rows
    }

    private func needsCaution(_ category: CleanupCategory) -> Bool {
        category == .trash || category == .installerPackages || category == .largeAppData
    }

    private var aiConfigured: Bool {
        CleanupAIScan.isConfigured
    }

    var body: some View {
        VStack(spacing: 0) {
            MDScanWorkbench(journey: cleanup.scanJourney, stages: JunkScanner.cleanupScanCategories.map(\.rawValue)) {
                content
            }
            if case .preview = cleanup.phase, cleanup.hasFreshPreview, cleanup.selectedCount > 0 {
                cleanupActionBar
            }
        }
        .background(MDTheme.content)
        .onAppear {
            aiSettings = AISettingsStore.load()
            // Only scan when navigator asks *and* we don't already have chat/page results.
            if nav.consumeCleanupScanFlag() {
                runScanIfNeeded()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await cleanup.reconcilePreviewOnReturn()
        }
        .onChange(of: cleanup.preparationFailure) { _, failure in
            if failure == .expiredPreview || failure == .changedTargets {
                confirmTrash = false
            }
        }
        .onChange(of: nav.shouldStartCleanupScan) { _, on in
            if on, nav.consumeCleanupScanFlag() {
                runScanIfNeeded()
            }
        }
        .onChange(of: cleanup.lastScanCompletedAt) { _, _ in
            // A new preview starts with a small visible window again; the full
            // result remains available through the category's "show more" row.
            itemDisplayLimits.removeAll()
        }
        .sheet(isPresented: $confirmTrash) {
            CleanupConfirmSheet(
                revocableItems: selectedRevocableItems,
                permanentItems: selectedPermanentItems,
                revocablePaths: selectedRevocableItems.flatMap { cleanup.previewPaths(for: $0) },
                permanentPaths: selectedPermanentItems.flatMap { cleanup.previewPaths(for: $0) },
                onCancel: { confirmTrash = false },
                onConfirm: {
                    confirmTrash = false
                    // Confirmation only cleans. Expiry never turns it into a scan.
                    cleanup.confirmTrash()
                }
            )
        }
    }

    private var selectedRevocableItems: [CleanableItem] {
        cleanup.allItems.filter { $0.isSelected && $0.risk != .skip && $0.category != .trash }
    }

    private var selectedPermanentItems: [CleanableItem] {
        cleanup.allItems.filter { $0.isSelected && $0.risk != .skip && $0.category == .trash }
    }

    /// 分组勾选 / 全选后展开受影响分组，方便核对选择。
    private func expandCategoriesWithSelection() {
        for g in cleanup.groups where g.items.contains(where: \.isSelected) {
            expanded.insert(g.category)
        }
    }

    /// 配好 AI → 规则扫 + AI 解读；未配 → 纯规则。用户点「扫描/重扫」= force。
    private func runScan(force: Bool = true, preservingSelection: Bool = false) {
        aiSettings = AISettingsStore.load()
        let useAI = aiConfigured
        cleanup.startScan(force: force, preservingSelection: preservingSelection) {
            Task { @MainActor in
                // 复用预览时：若已有 AI 文案则不再打 API
                await CleanupAIScan.enrichIfNeeded(service: cleanup, useAI: useAI)
            }
        }
    }

    /// 仅导航触发：只有 hasFreshPreview 才复用；过期/无完成时间/空都必须重扫。
    private func runScanIfNeeded() {
        if cleanup.phase.isBusy || cleanup.isAIEnriching { return }
        if cleanup.hasFreshPreview { return }
        runScan(force: true)
    }

    /// Only a current preview offers selection; invalid results return to the scan entry.
    private var canSelectPreview: Bool {
        cleanup.canEditSelection
    }

    private var canCleanSelection: Bool {
        cleanup.selectedCount > 0 && canSelectPreview
    }

    /// Selection actions belong only to a current preview.
    private var cleanupActionBar: some View {
        MDSelectionActionBar(selectedCount: cleanup.selectedCount,
            selectedBytes: Format.bytes(Double(cleanup.selectedBytes)), canClean: canCleanSelection,
            buttonIdentifier: "cleanup.cleanSelected",
            actionHelp: cleanup.hasStalePreview ? L10n.t("cleanup.rescan_required") : L10n.t("cleanup.review_selected"),
            action: { guard canCleanSelection else { return }; confirmTrash = true }) {
                if let failure = cleanup.preparationFailure {
                    Text(preparationFailureText(failure))
                        .font(.caption)
                        .foregroundStyle(MDTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if cleanup.hasStalePreview {
                    Label(L10n.t("cleanup.rescan_required"), systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(MDTheme.warning)
                }
        }
    }

    private func preparationFailureText(_ failure: CleanupPreparationFailure) -> String {
        switch failure {
        case .expiredPreview: return L10n.t("cleanup.failure.expired")
        case .changedTargets: return L10n.t("cleanup.failure.changed")
        case .noEligibleItems: return L10n.t("cleanup.failure.blocked")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch cleanup.phase {
        case .idle:
            if cleanup.preparationFailure == .expiredPreview || cleanup.preparationFailure == .changedTargets {
                rescanState
            } else if cleanup.scanJourney.status == .stopped {
                VStack(spacing: 0) {
                    MDScanActivityCard(kind: .cleanup, journey: cleanup.scanJourney, clock: scanAnimation,
                        title: L10n.t("scan.card.resume"),
                        detail: cleanup.groups.isEmpty ? nil : L10n.t("scan.card.saved"),
                        compact: !cleanup.groups.isEmpty, action: {
                            cleanup.continueScan {
                                Task { @MainActor in await CleanupAIScan.enrichIfNeeded(service: cleanup, useAI: aiConfigured) }
                            }
                        }, identifier: "cleanup.resumeScan")
                        .contextMenu { Button(L10n.t("common.rescan")) { runScan() } }
                        .padding(MDTheme.pagePadding)
                    if !cleanup.groups.isEmpty { previewState }
                }
            } else { idleState }
        case .scanning:
            VStack(spacing: 0) {
                MDScanActivityCard(kind: .cleanup, journey: cleanup.scanJourney, clock: scanAnimation,
                    title: cleanup.scanHint.isEmpty ? L10n.t("common.scanning") : ScanProgressL10n.localize(cleanup.scanHint),
                    compact: !cleanup.groups.isEmpty, stop: { cleanup.cancelScan() },
                    identifier: "cleanup.stopScan")
                    .padding(MDTheme.pagePadding)
                if !cleanup.groups.isEmpty { previewState }
            }
        case .preview:
            if cleanup.hasStalePreview {
                rescanState
            } else {
                previewState
            }
        case .cleaning(let progress):
            cleaningState(progress: progress)
        case .done(let freed, let count, let errors):
            doneState(freed: freed, count: count, errors: errors)
        case .failed(let msg):
            failedState(msg)
        }
    }

    private var idleState: some View {
        MDScanActivityCard(kind: .cleanup, journey: cleanup.scanJourney, clock: scanAnimation,
            title: L10n.t("scan.card.start"), detail: L10n.t("scan.card.cleanup_detail"),
            action: { runScan() }, identifier: "cleanup.scanPrimary")
            .padding(MDTheme.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rescanState: some View {
        MDScanActivityCard(kind: .cleanup, journey: cleanup.scanJourney, clock: scanAnimation,
            title: L10n.t("scan.card.rescan"),
            detail: L10n.t(cleanup.preparationFailure == .changedTargets ? "cleanup.rescan.changed_detail" : "cleanup.rescan.expired_detail"),
            action: { runScan() }, identifier: "cleanup.rescan")
            .padding(MDTheme.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewState: some View {
        VStack(spacing: 0) {
            summaryBar
            if let err = cleanup.lastAIError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(MDTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MDTheme.pagePadding)
                    .padding(.top, 6)
            }
            if let narrative = cleanup.aiNarrative, !narrative.isEmpty {
                DisclosureGroup(L10n.t("common.ai_review"), isExpanded: $showAIReview) {
                    MDAIResultCard(text: narrative).padding(.top, 6)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, MDTheme.pagePadding)
                .padding(.vertical, 8)
            }
            if cleanup.groups.isEmpty {
                VStack {
                    Spacer()
                    Text(L10n.t(cleanup.scanJourney.status == .stopped ? "scan.stopped_empty" : "cleanup.none"))
                        .foregroundStyle(MDTheme.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(previewRows) { row in
                                previewRow(row)
                                    .transition(.opacity)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: cleanup.groups.map(\.category))
                        .padding(.horizontal, MDTheme.pagePadding)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { focusPendingCategory(using: proxy) }
                    .onChange(of: cleanup.groups.map(\.category)) { _, _ in
                        focusPendingCategory(using: proxy)
                    }
                }
            }
        }
    }

    private func focusPendingCategory(using proxy: ScrollViewProxy) {
        guard let category = nav.cleanupFocusCategory,
              cleanup.groups.contains(where: { $0.category == category }) else { return }
        expanded.insert(category)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo("header:\(category.rawValue)", anchor: .top)
        }
        _ = nav.consumeCleanupFocusCategory()
    }

    private var selectedIncludesTrashEmpty: Bool {
        cleanup.allItems.contains { $0.isSelected && $0.category == .trash }
    }

    private var summaryBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                summaryContent.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                summaryActions
            }
            VStack(alignment: .leading, spacing: 8) {
                summaryContent
                summaryActions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, MDTheme.pagePadding)
        .padding(.vertical, 7)
        .background(MDTheme.surface.opacity(0.95))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MDTheme.separator).frame(height: 0.5)
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 2) {
                Text(cleanup.scanJourney.status == .running || cleanup.scanJourney.status == .stopped
                     ? L10n.t("cleanup.scan_found", cleanup.groups.reduce(0) { $0 + $1.items.count })
                     : L10n.t("cleanup.preview_total", cleanup.totalBytes == 0 ? "0 B" : Format.bytes(Double(cleanup.totalBytes))))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                if cleanup.groups.contains(where: \.isPartial) {
                    Label(L10n.t("cleanup.partial_scan"), systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(MDTheme.secondary)
                }
            if cleanup.isAIEnriching {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(cleanup.scanHint.isEmpty ? L10n.t("cleanup.ai_busy") : ScanProgressL10n.localize(cleanup.scanHint))
                        .font(.caption2)
                        .foregroundStyle(MDTheme.secondary)
                        .lineLimit(1)
                }
            }
            if selectedIncludesTrashEmpty {
                Text(L10n.t("cleanup.confirm.empty_action"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.warning)
            }
        }
    }

    /// Keep actions visible; small windows wrap the button groups instead of hiding them in a menu.
    private var summaryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summaryNavigationActions
                summarySelectionActions
            }
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) { summaryNavigationActions }
                HStack(spacing: 8) { summarySelectionActions }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var summaryNavigationActions: some View {
            Button { nav.route = .aiTools } label: {
                Label(L10n.t("route.aiTools"), systemImage: "sparkles")
            }
            .help(L10n.t("route.aiTools"))
            .accessibilityLabel(L10n.t("route.aiTools"))
            .accessibilityIdentifier("cleanup.aiTools")
            .fixedSize()
            if case .preview = cleanup.phase, !cleanup.hasStalePreview {
                Button { runScan(preservingSelection: true) } label: {
                    Label(L10n.t("cleanup.rescan"), systemImage: "arrow.clockwise")
                }
                .disabled(cleanup.isAIEnriching)
                .help(L10n.t("cleanup.rescan"))
                .accessibilityLabel(L10n.t("cleanup.rescan"))
                .accessibilityIdentifier("cleanup.rescan")
                .fixedSize()
            }
    }

    @ViewBuilder
    private var summarySelectionActions: some View {
                Button(L10n.t("cleanup.select_safe")) {
                    guard canSelectPreview else { return }
                    cleanup.selectLowRiskOnly()
                    expandCategoriesWithSelection()
                }
                .disabled(!canSelectPreview)
                .help(L10n.t("cleanup.select_safe_help"))
                .accessibilityIdentifier("cleanup.selectLowRisk")
                .fixedSize()
                Button(L10n.t("common.select_all")) {
                    guard canSelectPreview else { return }
                    cleanup.setAllSelected(true)
                    expandCategoriesWithSelection()
                }
                .disabled(!canSelectPreview || cleanup.selectableCount == 0 || cleanup.allSelectableSelected)
                .help(L10n.t("cleanup.select_all_help"))
                .accessibilityIdentifier("cleanup.selectAll")
                .fixedSize()
                Button(L10n.t("common.deselect_all")) {
                    guard canSelectPreview else { return }
                    cleanup.setAllSelected(false)
                }
                .disabled(!canSelectPreview || cleanup.selectedCount == 0)
                .help(L10n.t("cleanup.clear_selection_help"))
                .accessibilityIdentifier("cleanup.clearSelection")
                .fixedSize()
    }

    @ViewBuilder
    private func previewRow(_ row: PreviewRow) -> some View {
        switch row {
        case .header(let group):
            categoryHeader(group)
        case .caution(let group):
            VStack(alignment: .leading, spacing: 0) {
                Text(group.category.localizedIfCleaned)
                    .font(.system(size: 10.5))
                    .foregroundStyle(MDTheme.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                MDRowSeparator(leading: 0)
            }
            .background(groupRowBackground(last: group.items.isEmpty))
            .padding(.bottom, group.items.isEmpty ? MDTheme.resultCardGap : 0)
        case .item(_, let item, let isLast, let separator):
            VStack(spacing: 0) {
                itemRow(item)
                if separator { MDRowSeparator(leading: 36) }
            }
            .background(groupRowBackground(last: isLast))
            .padding(.bottom, isLast ? MDTheme.resultCardGap : 0)
        case .more(let category, let remaining, let limit):
            Button {
                let count = cleanup.groups.first(where: { $0.category == category })?.items.count ?? 0
                itemDisplayLimits[category] = min(limit + Self.itemPageSize, count)
            } label: {
                HStack {
                    Spacer()
                    Text(L10n.t("cleanup.show_more_items", remaining))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MDTheme.accent)
                    Spacer()
                }
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .background(groupRowBackground(last: true))
            .padding(.bottom, MDTheme.resultCardGap)
        }
    }

    private func categoryHeader(_ group: CleanupCategoryGroup) -> some View {
        let isOpen = expanded.contains(group.category)
        let caution = needsCaution(group.category)
        let selectable = group.items.filter { $0.risk != .skip }
        // Selection stays in the same leading column as item checkboxes.
        // The separate disclosure button never changes selection.
        return HStack(spacing: 8) {
                MDCheckbox(
                    L10n.t("cleanup.select_group", group.category.localizedTitle),
                    isOn: Binding(
                        get: {
                            !selectable.isEmpty && selectable.allSatisfy(\.isSelected)
                        },
                        set: { on in
                            guard canSelectPreview else { return }
                            cleanup.setAllSelected(on, in: group.category)
                            if on { expanded.insert(group.category) }
                        }
                    )
                )
                .disabled(!canSelectPreview || selectable.isEmpty)
                .help(L10n.t("cleanup.select_group_help"))
                .accessibilityIdentifier("cleanup.selectGroup.\(group.category.rawValue)")

                Button {
                    if isOpen { expanded.remove(group.category) }
                    else { expanded.insert(group.category) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MDTheme.secondary)
                            .frame(width: 10)
                        MDGroupIcon(
                            systemName: group.category.systemImage,
                            tint: caution ? MDTheme.warning : MDTheme.accent
                        )
                        HStack(spacing: 6) {
                            Text(group.category.localizedTitle)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(MDTheme.label)
                            Text("\(group.items.count)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(MDTheme.tertiary)
                        }
                        Spacer(minLength: 8)
                        Text(Format.bytes(Double(group.totalBytes)))
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(MDTheme.secondary)
                            .frame(minWidth: MDTheme.metaSizeWidth, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(group.category.localizedWhatIsIt)

            }
            .mdResultHeader()
            .background(groupRowBackground(first: true, last: !isOpen))
            .padding(.bottom, isOpen ? 0 : MDTheme.resultCardGap)
    }

    /// Continuous card fill without wrapping the entire category in an eager stack.
    private func groupRowBackground(first: Bool = false, last: Bool = false) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: first ? MDTheme.resultCardRadius : 0,
            bottomLeadingRadius: last ? MDTheme.resultCardRadius : 0,
            bottomTrailingRadius: last ? MDTheme.resultCardRadius : 0,
            topTrailingRadius: first ? MDTheme.resultCardRadius : 0,
            style: .continuous
        )
        .fill(MDTheme.surface)
    }

    /// 勾选 | 标题+路径(+说明) | 风险 | 大小 | Finder — 路径常显；多路径可展开全部
    private func itemRow(_ item: CleanableItem) -> some View {
        let previewPaths = cleanup.previewPaths(for: item)
        let pathCount = previewPaths.count
        let pathsOpen = expandedItemPaths.contains(item.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if item.risk == .skip {
                    MDCheckbox(item.localizedDisplayTitle, isOn: .constant(false))
                        .disabled(true)
                        .help(item.path)
                        .accessibilityIdentifier("cleanup.item.\(item.id)")
                    itemDescription(item)
                } else {
                    MDCheckbox(
                        item.localizedDisplayTitle,
                        isOn: Binding(
                            get: { cleanup.isItemSelected(id: item.id) },
                            set: {
                                guard canSelectPreview else { return }
                                cleanup.setSelected(itemID: item.id, selected: $0)
                            }
                        )
                    ) {
                        itemDescription(item)
                    }
                    .disabled(!canSelectPreview)
                    .help(item.path)
                    .accessibilityIdentifier("cleanup.item.\(item.id)")
                }

                if pathCount > 1 {
                    Button {
                        if pathsOpen { expandedItemPaths.remove(item.id) }
                        else { expandedItemPaths.insert(item.id) }
                    } label: {
                        Text(L10n.t("cleanup.paths_count", pathCount))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MDTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("cleanup.paths_expand_help"))
                    .padding(.top, 2)
                }

                riskTag(item.risk)
                    .padding(.top, 2)

                MDRowMeta(text: item.formattedSize, width: 76, emphasis: true)
                    .padding(.top, 2)

                Button {
                    cleanup.revealInFinder(path: item.path)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MDTheme.accent)
                .help(L10n.t("diskmap.reveal") + "\n" + item.path)
                .accessibilityLabel(L10n.t("diskmap.reveal_item", item.localizedDisplayTitle))
                .accessibilityIdentifier("cleanup.revealInFinder")
                .padding(.top, 2)
            }

            if pathsOpen, pathCount > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(previewPaths.enumerated()), id: \.offset) { _, p in
                        Text(homeRelative(p))
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(MDTheme.secondary)
                            .mdCopyPathMenu(p)
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, MDTheme.rowVerticalPadding)
    }

    private func itemDescription(_ item: CleanableItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.localizedDisplayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MDTheme.label)
                .lineLimit(1)
            Text(item.homeRelativePath)
                .font(.system(size: 11))
                .foregroundStyle(MDTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .mdCopyPathMenu(item.path)
            if item.ifCleaned.hasPrefix("ai_cleanup:") || item.ifCleaned.hasPrefix("cleanup_blocked:") {
                Text(item.localizedIfCleaned).font(.system(size: 10))
                    .foregroundStyle(MDTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let what = item.localizedWhatIsIt
            if !what.isEmpty,
               item.category == .installerPackages
                || item.category == .largeAppData
                || item.risk == .caution {
                Text(what)
                    .font(.system(size: 10))
                    .foregroundStyle(MDTheme.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let n = (path as NSString).standardizingPath
        if n.hasPrefix(home + "/") {
            return "~/" + String(n.dropFirst(home.count + 1))
        }
        return n
    }

    private func riskTag(_ risk: CleanupRisk) -> some View {
        let color: Color = {
            switch risk {
            case .safe, .rebuild: return MDTheme.success
            case .caution: return MDTheme.warning
            case .skip: return MDTheme.tertiary
            }
        }()
        return Text(risk.localizedLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .help(risk.localizedTip)
    }

    private func cleaningState(progress: Double) -> some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView(value: progress).frame(width: 240)
            Text(L10n.t("cleanup.cleaning"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func doneState(freed: UInt64, count: Int, errors: [String]) -> some View {
        let moved = cleanup.lastResult?.movedToTrashBytes ?? 0
        let completed = cleanup.lastResult?.succeededPaths.count ?? count
        let failedPaths = cleanup.lastResult?.failedPaths.count ?? 0
        let failureCount = failedPaths > 0 ? failedPaths : errors.count
        let hasFailures = failureCount > 0
        let canReview = failedPaths > 0 && !cleanup.groups.isEmpty
        let titleKey = hasFailures
            ? (completed > 0 ? "cleanup.done.partial" : "cleanup.done.incomplete")
            : "cleanup.done.title"

        return VStack(spacing: 12) {
            Spacer()
            Text(L10n.t(titleKey))
                .font(.system(size: 16, weight: .semibold))

            if completed > 0 {
                Text(completionSummary(freed: freed, moved: moved, count: completed))
                    .font(.system(size: 13))
                    .foregroundStyle(MDTheme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(L10n.t("cleanup.done.storage_help"))
            } else if !hasFailures {
                Text(L10n.t("cleanup.none"))
                    .font(.system(size: 13))
                    .foregroundStyle(MDTheme.secondary)
            }

            if hasFailures {
                if canReview {
                    Button {
                        cleanup.reviewFailedItems()
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.t("cleanup.done.unprocessed", failureCount))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MDTheme.warning)
                    .accessibilityLabel(L10n.t("cleanup.done.review_unprocessed", failureCount))
                } else {
                    Text(L10n.t("cleanup.done.unprocessed", failureCount))
                        .foregroundStyle(MDTheme.warning)
                }
                if let failures = cleanup.lastResult?.failures, !failures.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(CleanupFailureKind.allCases, id: \.self) { kind in
                                let items = failures.filter { $0.kind == kind }
                                if !items.isEmpty {
                                    DisclosureGroup {
                                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(item.name).font(.body.weight(.medium))
                                                Text(item.path).font(.caption).foregroundStyle(MDTheme.secondary)
                                                    .textSelection(.enabled)
                                            }.padding(.vertical, 4)
                                        }
                                    } label: {
                                        Text(L10n.t("cleanup.failure.\(kind.rawValue)") + " · \(items.count)")
                                    }
                                    Text(L10n.t("cleanup.reason.\(kind.rawValue)"))
                                        .font(.caption).foregroundStyle(MDTheme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }.frame(maxHeight: 240).frame(maxWidth: 560)
                }
                if !errors.isEmpty {
                    DisclosureGroup(L10n.t("cleanup.technical_details")) {
                        ScrollView {
                            Text(errors.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }.frame(maxWidth: 560)
                }
            }

            Button(L10n.t("cleanup.finish")) { cleanup.reset() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private func completionSummary(freed: UInt64, moved: UInt64, count: Int) -> String {
        if freed > 0, moved > 0 {
            return L10n.t("cleanup.done.compact_mixed", count, Format.bytes(Double(freed)), Format.bytes(Double(moved)))
        }
        if freed > 0 {
            return L10n.t("cleanup.done.compact_freed", count, Format.bytes(Double(freed)))
        }
        if moved > 0 {
            return L10n.t("cleanup.done.compact_moved", count, Format.bytes(Double(moved)))
        }
        return L10n.t("cleanup.done.compact_count", count)
    }

    private func failedState(_ msg: String) -> some View {
        MDScanActivityCard(kind: .cleanup, journey: cleanup.scanJourney, clock: scanAnimation,
            title: L10n.t("cleanup.retry"), detail: msg,
            action: { runScan() }, identifier: "cleanup.retry")
            .padding(MDTheme.pagePadding)
    }
}
