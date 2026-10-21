import SwiftUI
import CleanupKit
import AppKit
import MonitorKit

struct SoftwareView: View {
    @StateObject private var service = SoftwareService.shared
    @EnvironmentObject private var monitor: MonitorService
    @ObservedObject private var nav = AppNavigator.shared
    @State private var target: InstalledApp?
    @State private var cliTarget: CliTool?
    /// 折叠的档（默认全展开）
    @State private var collapsedTiers: Set<SoftwareSizeTier> = []
    @State private var showAIReview = false
    /// 深链卸载匹配失败的一次性提示
    @State private var unmatchedHint: String?
    /// 深链名称多匹配时的选择器
    @State private var deepLinkCandidates: [InstalledApp] = []
    @State private var showDeepLinkPicker = false
    @State private var focusedAppID: String?
    @State private var scrollTargetAppID: String?

    private var aiConfigured: Bool { SoftwareAIScan.isConfigured }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scanJourney: ScanJourney { service.listKind == .apps ? service.appScanJourney : service.cliScanJourney }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MDScanWorkbench(journey: scanJourney, stages: service.listKind == .apps
                ? ["scan.stage.apps", "scan.stage.verify"]
                : ["scan.stage.npm", "scan.stage.brew", "scan.stage.uv", "scan.stage.manual", "scan.stage.verify"]) {
            VStack(alignment: .leading, spacing: 0) {
            if service.listKind == .apps {
                if let unmatchedHint {
                    Text(unmatchedHint)
                        .font(.caption)
                        .foregroundStyle(MDTheme.secondary)
                        .padding(.horizontal, MDTheme.pagePadding)
                        .padding(.top, 4)
                }
                if service.isLoading && service.apps.isEmpty {
                    loading
                } else if let err = service.loadError {
                    Text(err).foregroundStyle(MDTheme.danger).padding(MDTheme.pagePadding)
                } else {
                    list.disabled(service.isLoading)
                }
            } else {
                if service.isCLILoading && service.cliTools.isEmpty {
                    cliLoading
                } else if let err = service.cliLoadError {
                    Text(err).foregroundStyle(MDTheme.danger).padding(MDTheme.pagePadding)
                } else {
                    cliList.disabled(service.isCLILoading)
                }
            }
            }
            }
        }
        .background(MDTheme.content)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: service.listKind == .apps ? service.apps.map(\.id) : service.cliTools.map(\.id))
        .onAppear {
            if service.apps.isEmpty {
                let deepLink = nav.pendingUninstallPath != nil
                    || nav.pendingUninstallBundleID != nil
                    || nav.pendingUninstallName != nil
                    || nav.softwareFocusPath != nil
                    || nav.softwareFocusBundleID != nil
                    || nav.softwareFocusName != nil
                if deepLink {
                    service.refresh(force: true) {
                        Task { @MainActor in
                            tryPresentPendingUninstall()
                            tryFocusPendingSoftware()
                        }
                    }
                } else {
                    runInventory(force: true)
                }
            } else if !service.hasFreshInventory {
                runInventory(force: true)
            } else {
                tryPresentPendingUninstall()
                tryFocusPendingSoftware()
            }
        }
        .onChange(of: service.listKind) { _, kind in
            if kind == .cli {
                ensureCLIInventory()
            }
        }
        .onChange(of: service.apps.count) { _, _ in
            tryPresentPendingUninstall()
            tryFocusPendingSoftware()
        }
        .onChange(of: nav.pendingUninstallPath) { _, _ in
            tryPresentPendingUninstall()
        }
        .onChange(of: nav.pendingUninstallBundleID) { _, _ in
            tryPresentPendingUninstall()
        }
        .onChange(of: nav.pendingUninstallName) { _, _ in
            tryPresentPendingUninstall()
        }
        .onChange(of: nav.softwareFocusPath) { _, _ in
            tryFocusPendingSoftware()
        }
        .onChange(of: nav.softwareFocusBundleID) { _, _ in
            tryFocusPendingSoftware()
        }
        .onChange(of: nav.softwareFocusName) { _, _ in
            tryFocusPendingSoftware()
        }
        .onDisappear {
            service.cancelInventoryWork()
        }
        .sheet(item: $target) { app in
            UninstallSheet(app: app) {
                target = nil
                nav.clearPendingUninstall()
                service.refresh()
            }
        }
        .confirmationDialog(
            L10n.t("software.deep_link.pick_title"),
            isPresented: $showDeepLinkPicker,
            titleVisibility: .visible
        ) {
            ForEach(deepLinkCandidates) { app in
                Button("\(app.name) · \(app.bundleIdentifier)") {
                    target = app
                    nav.clearPendingUninstall()
                    deepLinkCandidates = []
                }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                // 无法唯一确认时只打开列表并搜索
                if let name = nav.pendingUninstallName {
                    service.query = name
                } else if let bid = nav.pendingUninstallBundleID {
                    service.query = bid
                }
                nav.clearPendingUninstall()
                deepLinkCandidates = []
            }
        } message: {
            Text(L10n.t("software.deep_link.pick_message"))
        }
        .sheet(item: $cliTarget) { tool in
            CliUninstallSheet(tool: tool) {
                cliTarget = nil
                service.refreshCLI(force: true)
            }
        }
    }

    private func ensureCLIInventory(force: Bool = false) {
        if force || service.cliTools.isEmpty || !service.hasFreshCLIInventory {
            service.refreshCLI(force: true)
        }
    }

    private func runInventory(force: Bool = true) {
        SoftwareAIScan.runInventory(service: service, monitor: monitor, force: force)
    }

    private func tryPresentPendingUninstall() {
        guard target == nil, !showDeepLinkPicker else { return }
        let path = nav.pendingUninstallPath
        let bid = nav.pendingUninstallBundleID
        let name = nav.pendingUninstallName
        guard path != nil || bid != nil || name != nil else { return }
        guard !service.isLoading || !service.apps.isEmpty else { return }

        switch AppOwnership.resolveDeepLink(path: path, bundleID: bid, name: name, in: service.apps) {
        case .exact(let hit):
            target = hit
            nav.clearPendingUninstall()
        case .ambiguous(let hits):
            // 多匹配：显示选择器，绝不自动打开第一个卸载页
            deepLinkCandidates = hits
            showDeepLinkPicker = true
        case .none:
            if !service.isLoading, !service.apps.isEmpty {
                // 无法唯一确认：只打开软件列表并填入搜索，不自动开 Sheet
                if let name, !name.isEmpty {
                    service.query = name
                } else if let bid, !bid.isEmpty {
                    service.query = bid
                }
                nav.clearPendingUninstall()
                unmatchedHint = L10n.t("software.not_found", name ?? bid ?? path ?? L10n.t("software.this_app"))
            } else if service.apps.isEmpty {
                service.refresh()
            }
        }
    }

    private func tryFocusPendingSoftware() {
        guard nav.softwareFocusPath != nil || nav.softwareFocusBundleID != nil || nav.softwareFocusName != nil else { return }
        guard !service.isLoading || !service.apps.isEmpty else { return }
        guard let focus = nav.consumeSoftwareFocus() else { return }

        switch AppOwnership.resolveDeepLink(path: focus.path, bundleID: focus.bundleID, name: focus.name, in: service.apps) {
        case .exact(let hit):
            service.listKind = .apps
            service.query = ""
            if let group = service.tierGroups.first(where: { group in
                group.apps.contains(where: { $0.id == hit.id })
            }) {
                collapsedTiers.remove(group.tier)
            }
            focusedAppID = hit.id
            scrollTargetAppID = hit.id
        case .ambiguous:
            service.listKind = .apps
            focusedAppID = nil
            service.query = focus.name ?? focus.bundleID ?? focus.path ?? ""
        case .none:
            service.listKind = .apps
            focusedAppID = nil
            service.query = focus.name ?? focus.bundleID ?? focus.path ?? ""
            unmatchedHint = L10n.t("software.not_found", focus.name ?? focus.bundleID ?? focus.path ?? L10n.t("software.this_app"))
        }
    }

    private func openPreview(path: String) {
        if let hit = service.apps.first(where: { $0.path == path }) {
            target = hit
        }
    }

    private func toggleTier(_ tier: SoftwareSizeTier) {
        if collapsedTiers.contains(tier) {
            collapsedTiers.remove(tier)
        } else {
            collapsedTiers.insert(tier)
        }
    }

    // MARK: - Header

    private var header: some View {
        MDPageBar {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    kindSelector
                    Text("\(service.listKind == .cli ? service.filteredCLITools.count : service.filtered.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MDTheme.secondary)
                    Spacer(minLength: 8)
                    toolbarControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        kindSelector
                        Text("\(service.listKind == .cli ? service.filteredCLITools.count : service.filtered.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(MDTheme.secondary)
                        Spacer(minLength: 8)
                    }
                    toolbarControls
                }
            }
        }
    }

    private var kindSelector: some View {
        MDGlassTabs(tabs: SoftwareListKind.allCases.map { (id: $0, title: $0.localizedTitle) },
                    selection: $service.listKind)
            .fixedSize()
    }

    private var toolbarControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(MDTheme.tertiary)
                TextField(
                    service.listKind == .cli ? L10n.t("software.cli.search") : L10n.t("common.search"),
                    text: $service.query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: MDTheme.radiusButton, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MDTheme.radiusButton, style: .continuous)
                    .stroke(MDTheme.border, lineWidth: 0.5)
            )
            .frame(maxWidth: 220)

            Picker("", selection: $service.sort) {
                ForEach(SoftwareSort.allCases) { s in
                    Text(s.localizedTitle).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 116)

            if service.listKind == .apps {
                if service.isLoading || service.isAIEnriching {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(service.isAIEnriching ? L10n.t("software.ai_busy") : L10n.t("software.scanning_size"))
                            .font(.caption2)
                            .foregroundStyle(MDTheme.secondary)
                    }
                }
                if service.isLoading {
                    Button(L10n.t("scan.stop")) { service.cancelInventoryWork() }
                        .accessibilityIdentifier("software.stopScan")
                }
                Button { runInventory() } label: {
                    Label(L10n.t("common.rescan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.isLoading || service.isAIEnriching)
            } else {
                if service.isCLILoading {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("software.cli.loading"))
                            .font(.caption2)
                            .foregroundStyle(MDTheme.secondary)
                    }
                }
                if service.isCLILoading {
                    Button(L10n.t("scan.stop")) { service.cancelInventoryWork() }
                        .accessibilityIdentifier("software.stopScan")
                }
                Button { ensureCLIInventory(force: true) } label: {
                    Label(L10n.t("common.rescan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.isCLILoading)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text(L10n.t("software.loading"))
                .font(.system(size: 12))
                .foregroundStyle(MDTheme.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var cliLoading: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text(L10n.t("software.cli.loading"))
                .font(.system(size: 12))
                .foregroundStyle(MDTheme.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let err = service.lastAIError, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(MDTheme.warning)
                            .padding(.horizontal, 2)
                    }

                    if let narrative = service.aiNarrative, !narrative.isEmpty {
                        DisclosureGroup(L10n.t("common.ai_review"), isExpanded: $showAIReview) {
                            MDAIResultCard(text: narrative).padding(.top, 6)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }

                    if !service.aiPreviewActions.isEmpty {
                        previewActionsBar
                    }

                    // U8：去掉「体积分档 · 规则」标签行；档头 subtitle 已说明

                    let groups = service.tierGroups
                    if groups.isEmpty {
                        MDGroupedList {
                            MDListRowChrome(showSeparator: false, verticalPadding: 12) {
                                Text(service.query.isEmpty ? L10n.t("software.none") : L10n.t("software.no_match"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(MDTheme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        ForEach(groups) { group in
                            tierSection(group)
                        }
                    }
                }
                .padding(.horizontal, MDTheme.pagePadding)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollToFocusedApp(scrollTargetAppID, using: proxy) }
            .onChange(of: scrollTargetAppID) { _, id in
                scrollToFocusedApp(id, using: proxy)
            }
        }
    }

    private func scrollToFocusedApp(_ id: String?, using proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
            scrollTargetAppID = nil
        }
    }

    private var previewActionsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("software.optional_preview"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MDTheme.secondary)
            FlowActions(actions: service.aiPreviewActions) { action in
                openPreview(path: action.path)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 体积分档

    private func tierSection(_ group: SoftwareTierGroup) -> some View {
        let collapsed = collapsedTiers.contains(group.tier)
        let hasUnmeasured = group.apps.contains { $0.totalBytes == 0 }
        let allUnmeasured = group.apps.allSatisfy { $0.totalBytes == 0 }
        let displayedSize = allUnmeasured ? "—" : (hasUnmeasured ? "≥ " : "") + group.formattedTotal
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                toggleTier(group.tier)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MDTheme.tertiary)
                        .frame(width: 12)
                    Text(allUnmeasured
                         ? (AppLanguage.current.isEnglish ? "Size not measured" : "体积待计算")
                         : group.tier.localizedTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MDTheme.label)
                    Text(allUnmeasured ? "" : group.tier.localizedSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(MDTheme.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(L10n.t("software.count_size", group.apps.count, displayedSize))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(MDTheme.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                MDGroupedList {
                    LazyVStack(spacing: 0) {
                        ForEach(group.apps) { app in
                            appRow(app, showSeparator: app.id != group.apps.last?.id)
                        }
                    }
                }
            }
        }
    }

    private func appRow(_ app: InstalledApp, showSeparator: Bool) -> some View {
        MDListRowChrome(
            showSeparator: showSeparator,
            separatorLeading: MDTheme.entitySeparatorLeading,
            verticalPadding: MDTheme.rowVerticalPadding
        ) {
            HStack(spacing: MDTheme.entityIconSpacing) {
                MDEntityLeading(kind: .appIcon(app.icon))

                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MDTheme.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(app.bundleIdentifier + "\n" + app.path)

                if app.isSystemLocation {
                    MDTag(text: L10n.t("common.system"), tone: .neutral)
                }

                MDRowMeta(text: "v\(app.version)", width: MDTheme.metaVersionWidth)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(app.totalBytes > 0 ? app.formattedSize : L10n.t("software.size_on_demand"))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(MDTheme.tertiary)
                        .lineLimit(1)
                    if let detail = app.formattedSizeDetail {
                        Text(detail)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(MDTheme.tertiary.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: MDTheme.metaSizeWidth, alignment: .trailing)
                .help(app.formattedSizeDetail.map { "总计 \(app.formattedSize)（\($0)）\n\(app.path)" } ?? app.path)

                Button(app.canTrashAppBundle ? L10n.t("software.uninstall") : L10n.t("software.residuals")) {
                    if app.totalBytes == 0 { service.loadSize(for: app) }
                    target = app
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .background(focusedAppID == app.id ? MDTheme.surfaceSelected : Color.clear)
        .id(app.id)
    }

    // MARK: - CLI list

    private var cliList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                let tools = service.filteredCLITools
                if tools.isEmpty {
                    MDGroupedList {
                        MDListRowChrome(showSeparator: false, verticalPadding: 12) {
                            Text(service.query.isEmpty ? L10n.t("software.cli.none") : L10n.t("software.no_match"))
                                .font(.system(size: 13))
                                .foregroundStyle(MDTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    MDGroupedList {
                        LazyVStack(spacing: 0) {
                            ForEach(tools) { tool in
                                cliRow(tool, showSeparator: tool.id != tools.last?.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, MDTheme.pagePadding)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cliRow(_ tool: CliTool, showSeparator: Bool) -> some View {
        let programSize = tool.programBytes == 0 ? "0 B" : tool.formattedProgramSize
        let dataSize = tool.dataBytes == 0 ? "0 B" : tool.formattedDataSize
        return MDListRowChrome(
            showSeparator: showSeparator,
            separatorLeading: MDTheme.entitySeparatorLeading,
            verticalPadding: MDTheme.rowVerticalPadding
        ) {
            HStack(spacing: MDTheme.entityIconSpacing) {
                MDEntityLeading(
                    kind: .symbol(
                        tool.protected ? "lock.shield" : "terminal",
                        tint: tool.protected ? MDTheme.tertiary : MDTheme.accent
                    )
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tool.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MDTheme.label)
                            .lineLimit(1)
                        MDTag(text: tool.channel.localizedTitle, tone: .neutral)
                        if tool.isRunning {
                            MDTag(text: L10n.t("software.cli.running"), tone: .warning)
                        }
                        if tool.protected {
                            MDTag(text: L10n.t("software.cli.protected"), tone: .neutral)
                        }
                    }
                    Text(cliSubtitle(tool))
                        .font(.system(size: 11))
                        .foregroundStyle(MDTheme.tertiary)
                        .lineLimit(1)
                        .help(tool.detail.isEmpty ? tool.packageId : tool.detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(tool.formattedTotalSize)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(MDTheme.label)
                    Text(L10n.t("software.cli.size_split", programSize, dataSize))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(MDTheme.tertiary)
                        .lineLimit(1)
                }
                .frame(minWidth: MDTheme.metaSizeWidth, alignment: .trailing)
                .help(L10n.t("software.cli.size_help", programSize, dataSize))

                Button(tool.protected ? L10n.t("software.cli.protected") : L10n.t("software.uninstall")) {
                    guard !tool.protected else { return }
                    cliTarget = tool
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(tool.protected)
                .help(tool.protected ? L10n.t("software.cli.protected_help") : L10n.t("software.cli.uninstall_help"))
            }
        }
    }

    private func cliSubtitle(_ tool: CliTool) -> String {
        var parts: [String] = [tool.packageId]
        if !tool.bins.isEmpty {
            parts.append(tool.bins.prefix(3).joined(separator: ", "))
        }
        if !tool.agents.isEmpty {
            parts.append(L10n.t("software.cli.agents_count", tool.agents.count))
        }
        return parts.joined(separator: " · ")
    }
}

// 简单横向按钮流（避免引入复杂布局依赖）
private struct FlowActions: View {
    let actions: [SoftwareAIPreviewAction]
    var onTap: (SoftwareAIPreviewAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(actions) { a in
                Button {
                    onTap(a)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.title)
                                .font(.system(size: 12, weight: .semibold))
                            if !a.reason.isEmpty {
                                Text(a.reason)
                                    .font(.system(size: 10))
                                    .foregroundStyle(MDTheme.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(L10n.t("software.preview"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(MDTheme.border, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
