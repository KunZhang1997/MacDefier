import AppKit
import CleanupKit
import QuickLook
import SwiftUI

struct AIToolCleanupView: View {
    @StateObject private var model = AIToolCleanupService.shared
    @StateObject private var software = SoftwareService.shared
    @StateObject private var scanAnimation = MDScanAnimationClock()
    @ObservedObject private var nav = AppNavigator.shared
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.chinese.rawValue

    @State private var expanded = Set<String>()
    @State private var manuallyCollapsed = Set<String>()
    @State private var limits: [String: Int] = [:]
    @State private var confirmation: Confirmation?
    @State private var cliTarget: CliTool?
    @State private var quickLookURL: URL?

    // Background Services tab state
    @State private var serviceQuery = ""
    @State private var activeSectionCollapsed = false
    @State private var pausedSectionCollapsed = false
    @State private var serviceTrashTarget: UserLaunchAgentItem?
    @State private var serviceActionMessage: String?
    @State private var serviceActionIsError = false
    @State private var focusedServiceID: String?
    @State private var scrollTargetServiceID: String?
    @FocusState private var searchFieldFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Confirmation: Identifiable {
        let id = UUID()
        let revision: Int
        let items: [AICleanupCandidate]
        let resources: [AIResource]
        var runtimeItems: [AICleanupCandidate] { items.filter { $0.kind == .simulatorRuntime } }
        var hasOnlyRuntimes: Bool { !runtimeItems.isEmpty && resources.isEmpty }
        var ids: Set<String> { Set(items.map(\.id)) }
        var bytes: UInt64 { AIResourceTotals.candidateBytes(items) }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            if model.activeTab == .storage {
                storageBody
            } else {
                servicesBody
            }
        }
        .background(MDTheme.content)
        .onAppear {
            if nav.softwareServiceFocusLabel != nil {
                model.activeTab = .services
                ensureServicesLoaded(force: !software.hasFreshServicesInventory) {
                    tryFocusPendingService()
                }
            } else if model.activeTab == .services {
                ensureServicesLoaded(force: !software.hasFreshServicesInventory)
            } else {
                syncAutoExpandedGroups()
            }
        }
        .onChange(of: model.activeTab) { _, tab in
            serviceActionMessage = nil
            focusedServiceID = nil
            if tab == .services {
                ensureServicesLoaded(force: !software.hasFreshServicesInventory) {
                    tryFocusPendingService()
                }
            } else {
                syncAutoExpandedGroups()
            }
        }
        .onChange(of: serviceQuery) { _, _ in
            focusedServiceID = nil
        }
        .onChange(of: nav.softwareServiceFocusLabel) { _, newValue in
            guard newValue != nil else { return }
            model.activeTab = .services
            ensureServicesLoaded(force: !software.hasFreshServicesInventory) {
                tryFocusPendingService()
            }
        }
        .onChange(of: model.groups.map(\.id)) { _, _ in
            syncAutoExpandedGroups()
        }
        .onDisappear {
            model.cancelScan()
            software.cancelServicesScanIfRunning()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDefierFocusSearch)) { _ in
            guard model.activeTab == .services else { return }
            searchFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDefierRefreshCurrentRoute)) { _ in
            if model.activeTab == .services {
                guard !software.isServicesLoading, software.actingServicePaths.isEmpty else { return }
                focusedServiceID = nil
                software.refreshServices(force: true)
            } else {
                guard model.phase != .scanning, model.phase != .cleaning else { return }
                startNewScan()
            }
        }
        .quickLookPreview($quickLookURL)
        .sheet(item: $confirmation) { frozen in
            confirmationSheet(frozen)
        }
        .sheet(item: $cliTarget) { tool in
            CliUninstallSheet(tool: tool) { result in
                cliTarget = nil
                if let result {
                    SoftwareService.shared.markCLIToolCleaned(tool, result: result)
                    if SoftwareService.shared.isCLIToolCleaned(tool) {
                        model.markCLIToolCleaned(tool)
                    }
                }
            }
        }
        .confirmationDialog(
            serviceTrashTarget.map { L10n.t("software.services.trash_confirm_title", $0.displayName) } ?? "",
            isPresented: Binding(
                get: { serviceTrashTarget != nil },
                set: { if !$0 { serviceTrashTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = serviceTrashTarget {
                Button(L10n.t("software.services.trash_confirm_action"), role: .destructive) {
                    serviceTrashTarget = nil
                    performTrashService(item)
                }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                serviceTrashTarget = nil
            }
        } message: {
            if let item = serviceTrashTarget {
                Text(L10n.t("software.services.trash_confirm_body", item.label))
            }
        }
    }

    // MARK: - Unified Top Page Bar (`MDPageBar`)

    private var pageHeader: some View {
        MDPageBar {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    tabSelector
                    headerLeadingStatus
                    Spacer(minLength: 8)
                    headerTrailingControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        tabSelector
                        headerLeadingStatus
                        Spacer(minLength: 8)
                    }
                    headerTrailingControls.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var tabSelector: some View {
        MDGlassTabs(
            tabs: [
                (id: AIToolsTab.storage, title: L10n.t("aitools.tab.storage")),
                (id: AIToolsTab.services, title: L10n.t("software.tab.services")),
            ],
            selection: $model.activeTab
        )
        .fixedSize()
    }

    @ViewBuilder
    private var headerLeadingStatus: some View {
        let _ = appLanguageRaw
        if model.activeTab == .services {
            if model.phase == .scanning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.t("common.scanning"))
                        .font(.system(size: 11))
                        .foregroundStyle(MDTheme.tertiary)
                }
            } else if let msg = serviceActionMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(serviceActionIsError ? MDTheme.warning : MDTheme.success)
                    .lineLimit(1)
            }
        } else if model.hasPreview {
            HStack(spacing: 6) {
                Text(L10n.t("aitools.summary", model.measuredCount, AIToolCleanupCopy.bytes(Double(model.eligibleBytes))))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(MDTheme.secondary)
                    .lineLimit(1)
                if !inUseOwners.isEmpty {
                    let sep = AppLanguage.current.isEnglish ? ", " : "、"
                    Text("· " + L10n.t("aitools.in_use", inUseOwners.joined(separator: sep)))
                        .font(.system(size: 11))
                        .foregroundStyle(MDTheme.tertiary)
                        .lineLimit(1)
                        .help(L10n.t("aitools.in_use", inUseOwners.joined(separator: ", ")))
                }
            }
        }
    }

    @ViewBuilder
    private var headerTrailingControls: some View {
        if model.activeTab == .services {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(MDTheme.tertiary)
                    TextField(L10n.t("software.services.search"), text: $serviceQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFieldFocused)
                    if !serviceQuery.isEmpty {
                        Button {
                            serviceQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(MDTheme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("common.clear"))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: MDTheme.radiusButton, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MDTheme.radiusButton, style: .continuous)
                        .stroke(MDTheme.border, lineWidth: 0.5)
                )
                .frame(maxWidth: 210)

                Button {
                    focusedServiceID = nil
                    software.refreshServices(force: true)
                } label: {
                    Label(L10n.t("common.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(software.isServicesLoading || !software.actingServicePaths.isEmpty)
                .accessibilityIdentifier("aitools.services.refresh")
            }
        } else if hasScanContent || model.hasPreview {
            let canInteract = model.phase == .preview && !model.requiresRescan
            let hasBulkSelectable = !model.groups.allSatisfy { $0.selectable.filter { $0.kind != .simulatorRuntime }.isEmpty }
            HStack(spacing: 8) {
                if model.hasPreview {
                    Button(L10n.t("aitools.select_low_risk")) {
                        model.selectLowRiskOnly()
                        expandGroupsWithSelection()
                    }
                    .disabled(!canInteract || model.lowRiskCount == 0)
                    .help(L10n.t("cleanup.select_safe_help"))
                    .accessibilityIdentifier("aitools.selectLowRisk")

                    Button(L10n.t("common.select_all")) {
                        model.selectAllEligible()
                        expandGroupsWithSelection()
                    }
                    .disabled(!canInteract || !hasBulkSelectable)
                    .help(L10n.t("aitools.select_all_help"))
                    .accessibilityIdentifier("aitools.selectAll")

                    if model.selectedCount > 0 {
                        Button(L10n.t("common.deselect_all")) {
                            model.clearSelection()
                        }
                        .disabled(!canInteract)
                        .accessibilityIdentifier("aitools.deselectAll")
                    }
                }

                Button {
                    SoftwareService.shared.listKind = .cli
                    nav.route = .software
                } label: {
                    Label(L10n.t("aitools.open_cli"), systemImage: "terminal")
                }
                .disabled(model.phase == .cleaning)
                .help(L10n.t("aitools.open_cli"))

                if !showsScanActivity {
                    Button(action: startNewScan) {
                        Label(L10n.t("common.rescan"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.phase == .cleaning)
                    .accessibilityIdentifier("aitools.scan")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Tab 1: Storage & Runtimes

    private var storageBody: some View {
        VStack(spacing: 0) {
            MDScanWorkbench(
                journey: model.scanJourney,
                stages: AIToolCleanupService.scanStages.map { "scan.stage." + $0 }
            ) {
                VStack(spacing: 0) {
                    if model.scanJourney.status == .idle && model.phase == .idle && !model.hasPreview && !hasScanContent {
                        emptyState
                    } else {
                        if showsScanActivity {
                            scanActivity
                                .padding(.horizontal, MDTheme.pagePadding)
                                .padding(.top, 16)
                                .padding(.bottom, MDTheme.resultCardGap)
                        }
                        if hasScanContent || model.hasPreview {
                            storagePreview
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            if model.selectedCount > 0 || model.phase == .cleaning {
                footer
            }
        }
    }

    private var emptyState: some View {
        MDScanActivityCard(
            kind: .aiTools,
            journey: model.scanJourney,
            clock: scanAnimation,
            title: L10n.t("scan.card.start"),
            detail: L10n.t("scan.card.ai_detail"),
            action: startNewScan,
            identifier: "aitools.scanPrimary"
        )
        .padding(.horizontal, MDTheme.pagePadding)
        .padding(.top, 16)
        .padding(.bottom, MDTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hasScanContent: Bool {
        !model.groups.isEmpty || !model.issues.isEmpty || model.lastResult != nil
    }

    private var showsScanActivity: Bool {
        model.phase != .cleaning && (model.phase == .scanning || model.scanJourney.status == .stopped || model.requiresRescan)
    }

    private func startNewScan() {
        expanded.removeAll()
        manuallyCollapsed.removeAll()
        limits.removeAll()
        model.startScan()
    }

    /// Auto-expand only compact, directly actionable cache/runtime groups — never flood the screen with conversation UUID lists.
    private func syncAutoExpandedGroups() {
        let autoExpandableKinds: Set<AIDataKind> = [.cache, .oldVersion, .simulatorRuntime]
        for group in model.groups where autoExpandableKinds.contains(group.kind)
            && !group.selectable.isEmpty
            && !manuallyCollapsed.contains(group.id) {
            expanded.insert(group.id)
        }
    }

    private func expandGroupsWithSelection() {
        for group in model.groups where group.visible.contains(where: { model.selectedIDs.contains($0.id) }) {
            manuallyCollapsed.remove(group.id)
            expanded.insert(group.id)
        }
    }

    private func toggleGroupExpanded(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
            manuallyCollapsed.insert(id)
        } else {
            manuallyCollapsed.remove(id)
            expanded.insert(id)
        }
    }

    @ViewBuilder
    private var scanActivity: some View {
        if model.phase == .scanning {
            MDScanActivityCard(
                kind: .aiTools,
                journey: model.scanJourney,
                clock: scanAnimation,
                title: L10n.t(model.scanJourney.status == .running && model.scanJourney.activeID == nil ? "scan.waiting" : model.scanHint),
                compact: true,
                stop: { model.cancelScan() },
                identifier: "aitools.stop"
            )
        } else if model.scanJourney.status == .stopped {
            MDScanActivityCard(
                kind: .aiTools,
                journey: model.scanJourney,
                clock: scanAnimation,
                title: L10n.t("scan.card.resume"),
                detail: hasScanContent ? L10n.t("scan.card.saved") : nil,
                compact: true,
                action: { model.startScan(resuming: true) },
                identifier: "aitools.resume"
            )
            .contextMenu { Button(L10n.t("common.rescan"), action: startNewScan) }
        } else if model.requiresRescan && model.phase != .cleaning {
            MDScanActivityCard(
                kind: .aiTools,
                journey: model.scanJourney,
                clock: scanAnimation,
                title: L10n.t("scan.card.rescan"),
                detail: hasScanContent ? L10n.t("scan.card.saved") : nil,
                compact: hasScanContent || model.hasPreview,
                action: startNewScan,
                identifier: "aitools.scan"
            )
        }
    }

    private var inUseOwners: [String] {
        Set(model.groups.flatMap(\.all).filter { $0.state == .inUse }.map { $0.tool.name }).sorted()
    }

    private var storagePreview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MDTheme.resultCardGap) {
                if let result = model.lastResult {
                    resultView(result)
                }
                ForEach(model.issues, id: \.self) { issue in
                    Text(AIToolCleanupCopy.reason(issue))
                        .font(.system(size: 11))
                        .foregroundStyle(MDTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.groups) { group in
                    groupCard(group)
                        .transition(.opacity)
                }
                if model.groups.isEmpty && model.phase != .scanning && model.scanJourney.status != .stopped {
                    Text(L10n.t("aitools.no_results"))
                        .font(.system(size: 13))
                        .foregroundStyle(MDTheme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.groups.map(\.id))
            .padding(.horizontal, MDTheme.pagePadding)
            .padding(.top, showsScanActivity ? 4 : 16)
            .padding(.bottom, MDTheme.pagePadding)
        }
    }

    private func groupCard(_ group: AIToolCleanupGroup) -> some View {
        let isOpen = expanded.contains(group.id)
        let selectableIDs = Set(group.selectable.map(\.id))
        let hasSelectable = !selectableIDs.isEmpty
        let iconSpec = AIToolCleanupCopy.groupIcon(for: group)
        let displayedBytes: UInt64 = {
            if group.kind == .conversation {
                return group.eligibleBytes > 0 ? group.eligibleBytes : group.totalBytes
            }
            return group.eligibleBytes > 0 ? group.eligibleBytes : group.totalBytes
        }()

        return MDGroupedList {
            // Zero vertical padding on outer HStack so the expand Button covers 100% of the 48pt header height!
            HStack(spacing: 0) {
                if hasSelectable {
                    MDCheckbox(
                        L10n.t("aitools.select_group_section",
                               L10n.t("scan.stage." + group.section.rawValue),
                               AIToolCleanupCopy.groupCardTitle(group)),
                        isOn: Binding(
                            get: { selectableIDs.isSubset(of: model.selectedIDs) },
                            set: { _ in
                                model.toggleGroup(group)
                                if selectableIDs.isSubset(of: model.selectedIDs) {
                                    manuallyCollapsed.remove(group.id)
                                    expanded.insert(group.id)
                                }
                            }
                        )
                    )
                    .padding(.leading, MDTheme.resultInset)
                    .padding(.trailing, 8)
                    .disabled(model.phase != .preview || model.requiresRescan)
                    .accessibilityIdentifier("aitools.selectGroup." + group.id)
                }

                Button {
                    toggleGroupExpanded(group.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MDTheme.secondary)
                            .frame(width: 10)
                        MDGroupIcon(systemName: iconSpec.symbol, tint: iconSpec.tint)
                        Text(AIToolCleanupCopy.groupCardTitle(group))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(MDTheme.label)
                            .lineLimit(1)
                        Text("\(group.all.count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(MDTheme.tertiary)
                        Spacer(minLength: 8)
                        if group.kind != .tool && displayedBytes > 0 {
                            Text(AIToolCleanupCopy.bytes(Double(displayedBytes)))
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundStyle(group.eligibleBytes > 0 ? MDTheme.label : MDTheme.secondary)
                                .frame(minWidth: MDTheme.metaSizeWidth, alignment: .trailing)
                        }
                    }
                    .padding(.leading, hasSelectable ? 0 : MDTheme.resultInset)
                    .padding(.trailing, group.kind == .conversation ? 8 : MDTheme.resultInset)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("aitools.details_for_section",
                                           L10n.t("scan.stage." + group.section.rawValue),
                                           AIToolCleanupCopy.groupCardTitle(group)))
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("aitools.details." + group.id)

                if let owner = group.owner, group.kind == .conversation {
                    Picker(
                        L10n.t("aitools.age"),
                        selection: Binding(
                            get: { model.age(for: owner) },
                            set: { value in
                                model.setAge(value, for: owner)
                                if value != .dontList {
                                    manuallyCollapsed.remove(group.id)
                                    expanded.insert(group.id)
                                }
                            }
                        )
                    ) {
                        ForEach(AIConversationAge.allCases) { age in
                            Text(L10n.t("aitools.age." + age.rawValue)).tag(age)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 112)
                    .padding(.trailing, MDTheme.resultInset)
                    .disabled(model.phase != .preview)
                    .accessibilityLabel(L10n.t("aitools.age_for", owner.name))
                }
            }
            .mdRowHover()

            if isOpen {
                MDRowSeparator(leading: 0)
                if group.visible.isEmpty {
                    Text(L10n.t(group.kind == .conversation && group.owner.map { model.age(for: $0) == .dontList } == true
                                ? "aitools.pick_age" : "aitools.no_matching"))
                        .font(.system(size: 12))
                        .foregroundStyle(MDTheme.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let visibleSlice = Array(group.visible.prefix(limits[group.id] ?? 40))
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleSlice.enumerated()), id: \.element.id) { idx, item in
                            candidateRow(item, group: group)
                            if idx < visibleSlice.count - 1 {
                                MDRowSeparator(leading: MDTheme.checkSeparatorLeading)
                            }
                        }
                        if group.visible.count > visibleSlice.count {
                            MDRowSeparator(leading: MDTheme.checkSeparatorLeading)
                            Button {
                                limits[group.id] = (limits[group.id] ?? 40) + 40
                            } label: {
                                HStack {
                                    Spacer()
                                    Text(L10n.t("aitools.show_more", group.visible.count - visibleSlice.count))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(MDTheme.accent)
                                    Spacer()
                                }
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ item: AICleanupCandidate, group: AIToolCleanupGroup) -> some View {
        let isCleaned = model.isCleaned(item)
        let canToggle = !isCleaned && item.canSelect
        let showFinderButton = !isCleaned
            && item.kind != .simulatorRuntime
            && item.kind != .tool
            && !item.path.isEmpty

        return HStack(alignment: .center, spacing: 8) {
            if isCleaned {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(MDTheme.success)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                candidateDescription(item, group: group, isCleaned: true)
            } else if canToggle {
                MDCheckbox(
                    candidateDisplayTitle(item, group: group),
                    isOn: Binding(
                        get: { model.selectedIDs.contains(item.id) },
                        set: { _ in model.toggle(item) }
                    )
                ) {
                    candidateDescription(item, group: group, isCleaned: false)
                }
                .disabled(model.phase != .preview || model.requiresRescan)
            } else {
                Image(systemName: item.state == .inUse ? "lock.fill" : (item.kind == .tool ? "terminal" : "minus.circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(item.state == .inUse ? MDTheme.warning : MDTheme.tertiary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                candidateDescription(item, group: group, isCleaned: false)
            }

            if let badge = candidateBadge(item, isCleaned: isCleaned) {
                MDTag(text: badge.text, tone: badge.tone)
            }

            if let tool = item.cliTool {
                if !isCleaned && !SoftwareService.shared.isCLIToolCleaned(tool) {
                    Button(L10n.t("aitools.manage")) { cliTarget = tool }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.phase == .cleaning)
                }
            } else {
                let hasDisplaySize = !item.resources.isEmpty || (item.kind == .simulatorRuntime && item.bytes > 0)
                let sizeStr = !hasDisplaySize
                    ? "—"
                    : (item.metadata["sizeComplete"] == "false" ? "≥ " : "") + AIToolCleanupCopy.bytes(Double(item.bytes))
                MDRowMeta(text: sizeStr, width: 76, emphasis: !isCleaned)
            }

            if showFinderButton {
                Button {
                    guard FileManager.default.fileExists(atPath: item.path) else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MDTheme.accent)
                .help(L10n.t("diskmap.reveal") + "\n" + item.path)
                .accessibilityLabel(L10n.t("aitools.reveal", item.title))
            }
        }
        .opacity(isCleaned ? 0.65 : 1.0)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .mdRowHover()
        .help(AIToolCleanupCopy.reason(item.reason) + "\n" + item.path)
        .contextMenu {
            if !isCleaned && item.canSelect && model.phase == .preview && !model.requiresRescan {
                Button {
                    model.toggle(item)
                } label: {
                    Label(L10n.t("context.toggle_select"), systemImage: "checkmark.square")
                }
            }
            if let tool = item.cliTool, !isCleaned, !SoftwareService.shared.isCLIToolCleaned(tool), model.phase != .cleaning {
                Button {
                    cliTarget = tool
                } label: {
                    Label(L10n.t("aitools.manage"), systemImage: "terminal")
                }
            }
            if !isCleaned && item.kind != .simulatorRuntime && FileManager.default.fileExists(atPath: item.path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                } label: {
                    Label(L10n.t("diskmap.reveal"), systemImage: "folder")
                }
                Button {
                    quickLookURL = URL(fileURLWithPath: item.path)
                } label: {
                    Label(L10n.t("context.quick_look"), systemImage: "eye")
                }
            }
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            } label: {
                Label(L10n.t("common.copy_path"), systemImage: "doc.on.doc")
            }
        }
    }

    private func candidateDescription(_ item: AICleanupCandidate, group: AIToolCleanupGroup, isCleaned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(candidateDisplayTitle(item, group: group))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isCleaned ? MDTheme.secondary : MDTheme.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(candidateSubtitle(item, isCleaned: isCleaned))
                .font(.system(size: 11))
                .foregroundStyle(MDTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidateDisplayTitle(_ item: AICleanupCandidate, group: AIToolCleanupGroup) -> String {
        if item.kind == .simulatorRuntime || item.kind == .tool || group.owner != nil {
            return item.title
        }
        if item.title.localizedCaseInsensitiveContains(item.tool.name) {
            return item.title
        }
        return "\(item.tool.name) · \(item.title)"
    }

    private func candidateSubtitle(_ item: AICleanupCandidate, isCleaned: Bool) -> String {
        if item.kind == .simulatorRuntime {
            if item.reason == "runtime_deleting" {
                return L10n.t("aitools.reason.runtime_deleting")
            }
            if item.reason == "xcode_bundled_runtime" {
                return L10n.t("aitools.reason.xcode_bundled_runtime")
            }
            if let date = item.lastActivity, date > .distantPast {
                let formatted = date.formatted(.dateTime.year().month().day().locale(L10n.locale))
                return L10n.t("aitools.runtime_last_used_compact", formatted)
            }
            return L10n.t("aitools.runtime_unused_compact")
        }
        if !item.canSelect && !isCleaned && item.kind != .tool && item.kind != .worktree && item.kind != .conversation {
            return "\(AIToolCleanupCopy.reason(item.reason)) · \(relative(item.path))"
        }
        if item.kind == .model, let count = Int(item.metadata["sharedBlobCount"] ?? ""), count > 0 {
            if let full = UInt64(item.metadata["fullModelBytes"] ?? ""), full > item.bytes {
                return L10n.t("aitools.shared_blobs", count) + " · " + L10n.t("aitools.model_full_size", AIToolCleanupCopy.bytes(Double(full)))
            }
            return L10n.t("aitools.shared_blobs", count)
        }
        if item.kind == .worktree {
            return worktreeDetails(item)
        }
        return relative(item.path)
    }

    private func candidateBadge(_ item: AICleanupCandidate, isCleaned: Bool) -> (text: String, tone: MDTag.Tone)? {
        if isCleaned || (item.cliTool.map(SoftwareService.shared.isCLIToolCleaned) ?? false) {
            if item.reason == "runtime_deleting" {
                return (L10n.t("aitools.tag.reclaiming"), .accent)
            }
            return (L10n.t("software.cleaned_badge"), .success)
        }
        if item.reason == "runtime_deleting" {
            return (L10n.t("aitools.tag.reclaiming"), .accent)
        }
        switch item.state {
        case .inUse:
            return (L10n.t("cleanup.tag.in_use"), .warning)
        case .retained:
            return (L10n.t("aitools.state.retained"), .neutral)
        case .unknown:
            return (L10n.t("aitools.state.unknown"), .neutral)
        case .ready, .reviewOnly:
            return nil
        }
    }

    private var footer: some View {
        MDSelectionActionBar(
            selectedCount: model.selectedCount,
            selectedBytes: AIToolCleanupCopy.bytes(Double(model.selectedBytes)),
            canClean: model.canClean,
            progress: model.phase == .cleaning ? model.progress : nil,
            progressTitle: model.cleaningHasRuntimes ? L10n.t("aitools.removing") : L10n.t("aitools.moving"),
            buttonIdentifier: "aitools.trash",
            action: {
                guard model.canClean else { return }
                confirmation = Confirmation(
                    revision: model.previewRevision,
                    items: model.selectedCandidates,
                    resources: model.selectedResources
                )
            }
        ) { EmptyView() }
    }

    private func confirmationSheet(_ frozen: Confirmation) -> some View {
        let titleKey: String = {
            if frozen.hasOnlyRuntimes { return "aitools.confirm_runtime_title" }
            if !frozen.runtimeItems.isEmpty { return "aitools.confirm_mixed_title" }
            return "aitools.confirm_title"
        }()
        let bodyKey = frozen.hasOnlyRuntimes ? "aitools.confirm_runtime_body" : "aitools.confirm_body"
        let actionKey = frozen.hasOnlyRuntimes ? "aitools.confirm_runtime_action" : "aitools.confirm_action"
        return VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t(titleKey)).font(.title3.weight(.semibold))
            Text(L10n.t(bodyKey, frozen.items.count, AIToolCleanupCopy.bytes(Double(frozen.bytes))))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if !frozen.runtimeItems.isEmpty {
                Label(L10n.t("aitools.runtime_confirm_warning"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(MDTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(frozen.runtimeItems) { rt in
                        HStack(alignment: .top) {
                            Text("Xcode · \(rt.title)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(AIToolCleanupCopy.bytes(Double(rt.bytes)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .mdRowHover(cornerRadius: 4)
                    }
                    ForEach(frozen.resources, id: \.path) { resource in
                        HStack(alignment: .top) {
                            Text(relative(resource.path))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(AIToolCleanupCopy.bytes(Double(resource.bytes)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .mdRowHover(cornerRadius: 4)
                        .contextMenu {
                            if FileManager.default.fileExists(atPath: resource.path) {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resource.path)])
                                } label: {
                                    Label(L10n.t("diskmap.reveal"), systemImage: "folder")
                                }
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(resource.path, forType: .string)
                            } label: {
                                Label(L10n.t("common.copy_path"), systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                .padding(8)
            }
            .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(MDTheme.subtleBorder, lineWidth: 0.5)
            }
            if !frozen.resources.isEmpty {
                Text(L10n.t("aitools.trash_note")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.t("common.cancel")) { confirmation = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.t(actionKey)) {
                    confirmation = nil
                    model.cleanSelected(frozen.items, revision: frozen.revision)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canClean || model.selectedIDs != frozen.ids || model.previewRevision != frozen.revision)
            }
        }
        .padding(20).frame(minWidth: 480, idealWidth: 560, maxWidth: 640, minHeight: 300, idealHeight: 440)
    }

    private func resultView(_ result: CleanupResult) -> some View {
        let summaryText: String = {
            if result.movedToTrashBytes > 0 && result.freedBytes > 0 {
                return L10n.t("aitools.result_mixed",
                              AIToolCleanupCopy.bytes(Double(result.movedToTrashBytes)),
                              AIToolCleanupCopy.bytes(Double(result.freedBytes)))
            } else if result.freedBytes > 0 {
                return L10n.t("aitools.result_freed", AIToolCleanupCopy.bytes(Double(result.freedBytes)))
            } else if result.movedToTrashBytes == 0 && !result.errors.isEmpty {
                return L10n.t("aitools.result_none")
            }
            return L10n.t("aitools.result", AIToolCleanupCopy.bytes(Double(result.movedToTrashBytes)))
        }()
        return MDGroupedList {
            VStack(alignment: .leading, spacing: 6) {
                Label(summaryText, systemImage: result.errors.isEmpty ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(result.errors.isEmpty ? MDTheme.success : MDTheme.label)
                if !result.errors.isEmpty {
                    MDDisclosureBar(L10n.t("aitools.failures", result.errors.count), font: .caption, foreground: MDTheme.secondary) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(result.errors.prefix(20).enumerated()), id: \.offset) { _, error in
                                Text(AIToolCleanupCopy.reason(error))
                                    .font(.caption)
                                    .foregroundStyle(MDTheme.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Tab 2: Background Services (`~/Library/LaunchAgents`) — System Settings Style

    private func ensureServicesLoaded(force: Bool = false, completion: (() -> Void)? = nil) {
        if force || software.lastServicesInventoryAt == nil || !software.hasFreshServicesInventory {
            software.refreshServices(force: force) {
                Task { @MainActor in completion?() }
            }
        } else {
            completion?()
        }
    }

    private func tryFocusPendingService() {
        guard let rawFocus = nav.consumeSoftwareServiceFocus()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawFocus.isEmpty
        else { return }
        let labelHits = software.userServices.filter { $0.label.caseInsensitiveCompare(rawFocus) == .orderedSame }
        let hit: UserLaunchAgentItem? = {
            if let broken = labelHits.first(where: { !$0.targetExistsOnDisk }) { return broken }
            if let firstLabel = labelHits.first { return firstLabel }
            let nameHits = software.userServices.filter { $0.displayName.caseInsensitiveCompare(rawFocus) == .orderedSame }
            return nameHits.count == 1 ? nameHits.first : nil
        }()
        serviceQuery = ""
        if let hit {
            if hit.isLoaded && !software.isServiceTrashed(hit) {
                activeSectionCollapsed = false
            } else {
                pausedSectionCollapsed = false
            }
            focusedServiceID = hit.id
            scrollTargetServiceID = hit.id
        } else {
            focusedServiceID = nil
            serviceActionIsError = false
            serviceActionMessage = L10n.t("software.not_found", rawFocus)
        }
    }

    private var servicesBody: some View {
        let filtered = software.filteredServices(query: serviceQuery)
        let activeItems = filtered.filter { $0.isLoaded && !software.isServiceTrashed($0) }
        let inactiveItems = filtered.filter { !$0.isLoaded || software.isServiceTrashed($0) }

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if software.servicesProbeFailed {
                        Text(L10n.t("software.services.probe_failed"))
                            .font(.system(size: 12))
                            .foregroundStyle(MDTheme.warning)
                    }

                    if software.isServicesLoading && software.userServices.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.t("common.scanning"))
                                .font(.system(size: 13))
                                .foregroundStyle(MDTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else if filtered.isEmpty {
                        MDGroupedList {
                            MDListRowChrome(showSeparator: false, verticalPadding: 14) {
                                Text(serviceQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? L10n.t("software.services.none")
                                     : L10n.t("software.no_match"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(MDTheme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        if !activeItems.isEmpty {
                            serviceGroupSection(
                                title: L10n.t("aitools.services.group_active"),
                                items: activeItems,
                                collapsed: $activeSectionCollapsed
                            )
                        }
                        if !inactiveItems.isEmpty {
                            serviceGroupSection(
                                title: L10n.t("aitools.services.group_paused"),
                                items: inactiveItems,
                                collapsed: $pausedSectionCollapsed
                            )
                        }

                        Text(L10n.t("aitools.services.footer_note"))
                            .font(.system(size: 11))
                            .foregroundStyle(MDTheme.tertiary)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, MDTheme.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .onAppear { scrollToFocusedService(scrollTargetServiceID, using: proxy) }
            .onChange(of: scrollTargetServiceID) { _, id in
                scrollToFocusedService(id, using: proxy)
            }
        }
    }

    private func serviceGroupSection(
        title: String,
        items: [UserLaunchAgentItem],
        collapsed: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                collapsed.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MDTheme.tertiary)
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MDTheme.label)
                    Text("\(items.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(MDTheme.tertiary)
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .mdRowHover(cornerRadius: 6)
            .accessibilityValue(collapsed.wrappedValue ? "Collapsed" : "Expanded")

            if !collapsed.wrappedValue {
                MDGroupedList {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            serviceRow(item, showSeparator: item.id != items.last?.id)
                        }
                    }
                }
            }
        }
    }

    private func scrollToFocusedService(_ id: String?, using proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
            scrollTargetServiceID = nil
        }
    }

    private func serviceRow(_ item: UserLaunchAgentItem, showSeparator: Bool) -> some View {
        let isTrashed = software.isServiceTrashed(item)
        let isActing = software.isServiceActing(item)
        let canToggleSwitch = !isTrashed
            && !isActing
            && !software.servicesProbeFailed
            && item.runState != .unknown
            && (item.isLoaded || item.targetExistsOnDisk)

        return MDListRowChrome(
            showSeparator: showSeparator,
            separatorLeading: MDTheme.entitySeparatorLeading,
            verticalPadding: 8
        ) {
            HStack(spacing: MDTheme.entityIconSpacing) {
                serviceLeadingIcon(item, isTrashed: isTrashed)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isTrashed ? MDTheme.secondary : MDTheme.label)
                            .lineLimit(1)
                        if let tag = servicePrimaryTag(item, isTrashed: isTrashed) {
                            MDTag(text: tag.text, tone: tag.tone)
                        }
                    }
                    Text(serviceConciseSubtitle(item, isTrashed: isTrashed))
                        .font(.system(size: 11))
                        .foregroundStyle(MDTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isTrashed {
                    Text(L10n.t("software.cleaned_badge"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MDTheme.tertiary)
                } else if !item.targetExistsOnDisk && !item.isLoaded {
                    Button(L10n.t("software.services.trash")) {
                        serviceTrashTarget = item
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isActing || software.servicesProbeFailed || item.runState == .unknown)
                    .help(L10n.t("software.services.trash_help"))
                } else {
                    HStack(spacing: 8) {
                        ZStack {
                            if isActing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Toggle(
                                    item.displayName,
                                    isOn: Binding(
                                        get: { item.isLoaded },
                                        set: { wantLoaded in
                                            if wantLoaded {
                                                performResumeService(item)
                                            } else {
                                                performPauseService(item)
                                            }
                                        }
                                    )
                                )
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                                .disabled(!canToggleSwitch)
                                .help(item.isLoaded
                                      ? L10n.t("software.services.pause_help")
                                      : L10n.t("software.services.resume_help"))
                            }
                        }
                        .frame(width: 38, height: 20, alignment: .center)

                        Menu {
                            Button {
                                guard FileManager.default.fileExists(atPath: item.plistPath) else { return }
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
                            } label: {
                                Label(L10n.t("diskmap.reveal"), systemImage: "folder")
                            }
                            if !software.servicesProbeFailed && item.runState != .unknown {
                                Divider()
                                Button(role: .destructive) {
                                    serviceTrashTarget = item
                                } label: {
                                    Label(L10n.t("software.services.trash"), systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(MDTheme.tertiary)
                                .frame(width: 22, height: 22)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(isActing)
                    }
                }
            }
            .opacity(isTrashed ? 0.6 : 1.0)
        }
        .background(focusedServiceID == item.id ? MDTheme.surfaceSelected : Color.clear)
        .mdRowHover()
        .help(item.label + "\n" + item.plistPath + (item.targetPath.map { "\n" + $0 } ?? ""))
        .contextMenu {
            if !isTrashed {
                if item.isLoaded {
                    Button(L10n.t("software.services.pause")) {
                        performPauseService(item)
                    }
                } else if item.runState == .paused && item.targetExistsOnDisk {
                    Button(L10n.t("software.services.resume")) {
                        performResumeService(item)
                    }
                }
                if !software.servicesProbeFailed && item.runState != .unknown {
                    Button(L10n.t("software.services.trash")) {
                        serviceTrashTarget = item
                    }
                }
                if FileManager.default.fileExists(atPath: item.plistPath) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
                    } label: {
                        Label(L10n.t("diskmap.reveal"), systemImage: "folder")
                    }
                }
                Divider()
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            } label: {
                Label(L10n.t("software.services.copy_label"), systemImage: "doc.on.doc")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.plistPath, forType: .string)
            } label: {
                Label(L10n.t("common.copy_path"), systemImage: "folder.badge.gearshape")
            }
        }
        .id(item.id)
    }

    @ViewBuilder
    private func serviceLeadingIcon(_ item: UserLaunchAgentItem, isTrashed: Bool) -> some View {
        if isTrashed {
            MDEntityLeading(kind: .symbol("checkmark.circle.fill", tint: MDTheme.success))
        } else if let appPath = item.appBundlePath {
            MDAppIcon(path: appPath, fallbackSymbol: "terminal")
        } else {
            let lower = item.label.lowercased()
            let sym: String = {
                if !item.targetExistsOnDisk { return "exclamationmark.circle" }
                if lower.contains("mysql") || lower.contains("postgres") || lower.contains("redis") || lower.contains("mongo") {
                    return "cylinder.split.1x2"
                }
                if lower.contains("ollama") || lower.contains("openclaw") || lower.contains("codex") || lower.contains("claude") {
                    return "cpu"
                }
                return "terminal"
            }()
            let tint: Color = !item.targetExistsOnDisk
                ? MDTheme.warning
                : (item.isLoaded ? MDTheme.accent : MDTheme.secondary)
            MDEntityLeading(kind: .symbol(sym, tint: tint))
        }
    }

    private func servicePrimaryTag(_ item: UserLaunchAgentItem, isTrashed: Bool) -> (text: String, tone: MDTag.Tone)? {
        if isTrashed { return nil }
        if !item.targetExistsOnDisk {
            return (L10n.t("software.services.target_missing"), .warning)
        }
        if item.isKeepAlive {
            return (L10n.t("software.services.keep_alive"), .neutral)
        }
        return nil
    }

    private func serviceConciseSubtitle(_ item: UserLaunchAgentItem, isTrashed: Bool) -> String {
        if isTrashed {
            return L10n.t("aitools.reason.cleaned")
        }
        let stateText: String = {
            switch item.runState {
            case .running:
                if let pid = item.pid {
                    return L10n.t("software.services.state_running_pid", pid)
                }
                return L10n.t("software.cli.running")
            case .loadedIdle:
                return L10n.t("software.services.state_loaded")
            case .paused:
                return L10n.t("software.services.state_paused")
            case .unknown:
                return L10n.t("software.services.state_unknown")
            }
        }()
        let originText: String = {
            if item.label.lowercased().hasPrefix("homebrew.mxcl.") {
                return "Homebrew"
            }
            if let target = item.targetPath, !target.isEmpty {
                return relative(target)
            }
            if let prog = item.programPath, !prog.isEmpty {
                return relative(prog)
            }
            return item.label
        }()
        return "\(stateText) · \(originText)"
    }

    private func performPauseService(_ item: UserLaunchAgentItem) {
        Task {
            let res = await software.pauseService(item)
            if res.ok {
                serviceActionIsError = false
                serviceActionMessage = L10n.t("software.services.msg_paused", item.displayName)
            } else {
                serviceActionIsError = true
                serviceActionMessage = serviceErrorCopy(res.errorCode, name: item.displayName)
            }
        }
    }

    private func performResumeService(_ item: UserLaunchAgentItem) {
        Task {
            let res = await software.resumeService(item)
            if res.ok {
                serviceActionIsError = false
                serviceActionMessage = L10n.t("software.services.msg_resumed", item.displayName)
            } else {
                serviceActionIsError = true
                serviceActionMessage = serviceErrorCopy(res.errorCode, name: item.displayName)
            }
        }
    }

    private func performTrashService(_ item: UserLaunchAgentItem) {
        Task {
            let res = await software.trashService(item)
            if res.ok {
                serviceActionIsError = false
                serviceActionMessage = L10n.t("software.services.msg_trashed", item.displayName)
            } else {
                serviceActionIsError = true
                serviceActionMessage = serviceErrorCopy(res.errorCode, name: item.displayName)
            }
        }
    }

    private func serviceErrorCopy(_ code: String?, name: String) -> String {
        switch code {
        case "changed": return L10n.t("software.services.err_changed")
        case "busy": return L10n.t("software.services.err_busy")
        case "target_missing": return L10n.t("software.services.target_missing_help")
        case "status_probe_failed": return L10n.t("software.services.probe_failed")
        case "pause_failed": return L10n.t("software.services.err_pause_failed", name)
        case "resume_failed": return L10n.t("software.services.err_resume_failed", name)
        default: return L10n.t("software.services.err_trash_failed", name)
        }
    }

    // MARK: - Formatting Helpers

    private func relative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
    }

    private func worktreeDetails(_ item: AICleanupCandidate) -> String {
        guard item.metadata["gitStatus"] == "known" else { return L10n.t("aitools.git_unknown") }
        return L10n.t(
            "aitools.git_status",
            Int(item.metadata["trackedChanges"] ?? "") ?? 0,
            Int(item.metadata["untrackedFiles"] ?? "") ?? 0,
            Int(item.metadata["ignoredFiles"] ?? "") ?? 0
        )
    }
}

enum AIToolCleanupCopy {
    static func issueSection(_ raw: String) -> AIDataSection? {
        let code = raw.replacingOccurrences(of: "ai_cleanup_", with: "")
        if code.hasPrefix("runtime_") { return .devRuntimes }
        if code.hasPrefix("model") { return .models }
        if code.hasPrefix("conversation_") { return .conversations }
        if code.hasPrefix("worktree_") { return .worktrees }
        return nil
    }

    static func bytes(_ value: Double) -> String {
        value == 0 ? "0 B" : Format.bytes(value)
    }

    static func reason(_ raw: String) -> String {
        let code = String(raw.split(separator: ":", maxSplits: 1).first ?? Substring(raw))
            .replacingOccurrences(of: "ai_cleanup_", with: "")
        let key = "aitools.reason." + code
        let value = L10n.t(key)
        if value != key { return value }
        return L10n.t("aitools.reason.default")
    }

    static func groupTitle(_ group: AIToolCleanupGroup) -> String {
        if let owner = group.owner, group.kind == .conversation {
            return L10n.t("aitools.group.conversation", owner.name)
        }
        return L10n.t("aitools.group." + group.kind.rawValue)
    }

    /// Disambiguates `.appData` vs `.cliData` cache/leftover groups without needing redundant outer section headings.
    static func groupCardTitle(_ group: AIToolCleanupGroup) -> String {
        if let owner = group.owner, group.kind == .conversation {
            return L10n.t("aitools.group.conversation", owner.name)
        }
        if group.kind == .cache && group.section == .cliData {
            return L10n.t("aitools.group.cli_cache")
        }
        if group.kind == .leftover && group.section == .cliData {
            return L10n.t("aitools.group.cli_leftover")
        }
        return L10n.t("aitools.group." + group.kind.rawValue)
    }

    static func groupIcon(for group: AIToolCleanupGroup) -> (symbol: String, tint: Color) {
        switch group.kind {
        case .cache:
            return (group.section == .cliData ? "terminal" : "shippingbox", MDTheme.accent)
        case .oldVersion:
            return ("clock.arrow.circlepath", MDTheme.accent)
        case .simulatorRuntime:
            return ("iphone", MDTheme.warning)
        case .leftover:
            return ("folder.badge.questionmark", MDTheme.secondary)
        case .tool:
            return ("terminal", MDTheme.secondary)
        case .conversation:
            return ("bubble.left.and.bubble.right", MDTheme.secondary)
        case .model:
            return ("cpu", MDTheme.accent)
        case .worktree:
            return ("arrow.triangle.branch", MDTheme.secondary)
        case .database:
            return ("cylinder.split.1x2", MDTheme.secondary)
        }
    }
}
