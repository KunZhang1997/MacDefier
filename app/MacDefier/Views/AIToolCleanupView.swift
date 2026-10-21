import AppKit
import CleanupKit
import SwiftUI

struct AIToolCleanupView: View {
    @StateObject private var model = AIToolCleanupService.shared
    @StateObject private var scanAnimation = MDScanAnimationClock()
    @ObservedObject private var nav = AppNavigator.shared
    @State private var expanded = Set<String>()
    @State private var limits: [String: Int] = [:]
    @State private var confirmation: Confirmation?
    @State private var cliTarget: CliTool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Confirmation: Identifiable {
        let id = UUID()
        let revision: Int
        let items: [AICleanupCandidate]
        let resources: [AIResource]
        var ids: Set<String> { Set(items.map(\.id)) }
        var bytes: UInt64 { AIResourceTotals.bytes(resources) }
    }

    var body: some View {
        VStack(spacing: 0) {
            MDScanWorkbench(journey: model.scanJourney,
                stages: AIToolCleanupService.scanStages.map { "scan.stage." + $0 }) {
                VStack(spacing: 0) {
                    if model.phase == .idle && !model.hasPreview && !hasScanContent {
                        fullPageActivity
                    } else {
                        preview
                    }
                }
            }
            if model.selectedCount > 0 || model.phase == .cleaning {
                footer
            }
        }
        .background(MDTheme.content)
        .onDisappear { model.cancelScan() }
        .sheet(item: $confirmation) { frozen in
            confirmationSheet(frozen)
        }
        .sheet(item: $cliTarget) { tool in
            CliUninstallSheet(tool: tool) {
                cliTarget = nil
                if model.requiresRescan { model.startScan() }
            }
        }
    }

    private var emptyState: some View {
        MDScanActivityCard(kind: .aiTools, journey: model.scanJourney, clock: scanAnimation,
            title: L10n.t("scan.card.start"), detail: L10n.t("scan.card.ai_detail"),
            action: startNewScan, identifier: "aitools.scanPrimary")
            .padding(MDTheme.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var fullPageActivity: some View {
        Group {
            if model.scanJourney.status == .stopped || model.requiresRescan {
                scanActivity.padding(MDTheme.pagePadding)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasScanContent: Bool {
        !model.groups.isEmpty || !model.issues.isEmpty || model.lastResult != nil
    }

    private var showsScanActivity: Bool {
        model.phase == .scanning || model.scanJourney.status == .stopped || model.requiresRescan
    }

    private func startNewScan() {
        expanded.removeAll()
        limits.removeAll()
        model.startScan()
    }

    @ViewBuilder
    private var scanActivity: some View {
        if model.phase == .scanning {
            MDScanActivityCard(kind: .aiTools, journey: model.scanJourney, clock: scanAnimation,
                title: L10n.t(model.scanJourney.status == .running && model.scanJourney.activeID == nil
                              ? "scan.waiting" : model.scanHint), compact: hasScanContent,
                stop: { model.cancelScan() }, identifier: "aitools.stop")
        } else if model.scanJourney.status == .stopped {
            MDScanActivityCard(kind: .aiTools, journey: model.scanJourney, clock: scanAnimation,
                title: L10n.t("scan.card.resume"),
                detail: hasScanContent ? L10n.t("scan.card.saved") : nil,
                compact: hasScanContent, action: { model.startScan(resuming: true) },
                identifier: "aitools.resume")
                .contextMenu { Button(L10n.t("common.rescan"), action: startNewScan) }
        } else if model.requiresRescan && model.phase != .cleaning {
            MDScanActivityCard(kind: .aiTools, journey: model.scanJourney, clock: scanAnimation,
                title: L10n.t("scan.card.rescan"),
                detail: hasScanContent ? L10n.t("scan.card.saved") : nil,
                compact: hasScanContent, action: startNewScan, identifier: "aitools.scan")
        }
    }

    private var inUseOwners: [String] {
        Set(model.groups.flatMap(\.all).filter { $0.state == .inUse }.map { $0.tool.name }).sorted()
    }

    private var resultHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasPreview
                     ? L10n.t("aitools.summary", model.measuredCount, AIToolCleanupCopy.bytes(Double(model.eligibleBytes)))
                     : L10n.t("scan.card.results"))
                    .font(.subheadline.weight(.semibold))
                if !inUseOwners.isEmpty {
                    Text(L10n.t("aitools.in_use", inUseOwners.joined(separator: ", ")))
                        .font(.caption2)
                        .foregroundStyle(MDTheme.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                SoftwareService.shared.listKind = .cli
                nav.route = .software
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .disabled(model.phase == .cleaning)
            .help(L10n.t("aitools.open_cli"))
            .accessibilityLabel(L10n.t("aitools.open_cli"))
            if !showsScanActivity {
                Button(action: startNewScan) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.phase == .cleaning)
                .help(L10n.t("scan.card.rescan"))
                .accessibilityLabel(L10n.t("scan.card.rescan"))
                .accessibilityIdentifier("aitools.scan")
            }
        }
    }

    private var preview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MDTheme.resultCardGap) {
                if showsScanActivity { scanActivity }
                if hasScanContent || (model.hasPreview && model.phase != .scanning) { resultHeader }
                if model.hasPreview { selectionControls }
                if let result = model.lastResult { resultView(result) }
                ForEach(model.issues.filter { AIToolCleanupCopy.issueSection($0) == nil }, id: \.self) { issue in
                    Label(AIToolCleanupCopy.reason(issue), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(issue)
                }
                ForEach(AIDataSection.allCases, id: \.rawValue) { section in
                    dataSection(section).transition(.opacity)
                }
                if model.groups.isEmpty && model.phase != .scanning && model.scanJourney.status != .stopped {
                    Text(L10n.t("aitools.no_results"))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.groups.map(\.id))
            .padding(MDTheme.pagePadding)
        }
    }

    @ViewBuilder
    private func dataSection(_ section: AIDataSection) -> some View {
        let groups = model.groups.filter { $0.section == section }
        let issues = model.issues.filter { AIToolCleanupCopy.issueSection($0) == section }
        if !groups.isEmpty || !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.t("scan.stage." + section.rawValue)).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 16)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t("scan.stage." + section.rawValue)).font(.subheadline.weight(.semibold))
                    }
                }
                ForEach(issues, id: \.self) { issue in
                    Label(AIToolCleanupCopy.reason(issue), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).help(issue)
                }
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        groupView(group)
                        if group.id != groups.last?.id { Divider().padding(.leading, 42) }
                    }
                }
                .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: MDTheme.resultCardRadius))
            }
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 12) {
            Button(L10n.t("common.select_all")) { model.selectAllEligible() }
                .disabled(model.groups.allSatisfy { $0.selectable.isEmpty })
                .help(L10n.t("aitools.select_all_help"))
                .accessibilityIdentifier("aitools.selectAll")
            Button(L10n.t("common.deselect_all")) { model.clearSelection() }
                .disabled(model.selectedCount == 0)
                .accessibilityIdentifier("aitools.deselectAll")
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .disabled(model.phase != .preview || model.requiresRescan)
    }

    private func groupView(_ group: AIToolCleanupGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                groupCheckbox(group)
                Spacer(minLength: 5)
                if let owner = group.owner, group.kind == .conversation {
                    Picker(L10n.t("aitools.age"), selection: Binding(get: { model.age(for: owner) }, set: { value in
                        model.setAge(value, for: owner)
                        if value != .dontList { expanded.insert(group.id) }
                    })) {
                        ForEach(AIConversationAge.allCases) { age in
                            Text(L10n.t("aitools.age." + age.rawValue)).tag(age)
                        }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 130)
                    .disabled(model.phase != .preview)
                    .accessibilityLabel(L10n.t("aitools.age_for", owner.name))
                } else if group.kind != .tool && !group.selectable.isEmpty {
                    Text(AIToolCleanupCopy.bytes(Double(group.eligibleBytes)))
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(group.eligibleBytes > 0 ? MDTheme.label : MDTheme.secondary)
                        .help(L10n.t("aitools.eligible_help"))
                        .accessibilityLabel(L10n.t("aitools.eligible", AIToolCleanupCopy.bytes(Double(group.eligibleBytes))))
                }
                Button {
                    if !expanded.insert(group.id).inserted { expanded.remove(group.id) }
                } label: {
                    Image(systemName: expanded.contains(group.id) ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 24, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("aitools.details_for", AIToolCleanupCopy.groupTitle(group)))
            }
            .mdResultHeader()
            if expanded.contains(group.id) {
                Divider().padding(.leading, 42)
                if group.visible.isEmpty {
                    Text(L10n.t(group.kind == .conversation && group.owner.map { model.age(for: $0) == .dontList } == true
                                ? "aitools.pick_age" : "aitools.no_matching"))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(group.visible.prefix(limits[group.id] ?? 40))) { item in
                            candidateRow(item)
                            if item.id != group.visible.last?.id { Divider().padding(.leading, 42) }
                        }
                        if group.visible.count > (limits[group.id] ?? 40) {
                            Button(L10n.t("aitools.show_more", group.visible.count - (limits[group.id] ?? 40))) {
                                limits[group.id] = (limits[group.id] ?? 40) + 40
                            }
                            .buttonStyle(.borderless).padding(10)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func groupCheckbox(_ group: AIToolCleanupGroup) -> some View {
        if !group.selectable.isEmpty {
            let ids = Set(group.selectable.map(\.id))
            MDCheckbox(L10n.t("aitools.select_group", AIToolCleanupCopy.groupTitle(group)),
                       isOn: Binding(get: { ids.isSubset(of: model.selectedIDs) }, set: { _ in model.toggleGroup(group) })) {
                groupLabel(group)
            }
                .disabled(model.phase != .preview || model.requiresRescan)
        } else {
            HStack(spacing: 10) {
                Image(systemName: group.kind == .tool ? "terminal" : group.kind == .conversation ? "bubble.left.and.bubble.right" : "info.circle")
                    .font(.caption).foregroundStyle(.tertiary).frame(width: 28)
                    .accessibilityLabel(L10n.t(group.kind == .conversation ? "aitools.conversation_managed" : "aitools.review_only"))
                groupLabel(group)
            }
        }
    }

    private func groupLabel(_ group: AIToolCleanupGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AIToolCleanupCopy.groupTitle(group)).font(.callout.weight(.semibold))
            Text(groupSummary(group)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func candidateRow(_ item: AICleanupCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if item.canSelect {
                MDCheckbox(item.title, isOn: Binding(get: { model.selectedIDs.contains(item.id) }, set: { _ in model.toggle(item) }))
                    .disabled(model.phase != .preview || model.requiresRescan)
            } else {
                Image(systemName: item.state == .inUse ? "lock.fill" : "doc.text.magnifyingglass")
                    .font(.caption).foregroundStyle(.tertiary).frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if item.kind != .tool {
                        Text(L10n.t("aitools.state." + item.state.rawValue))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(item.tool.name + " · " + AIToolCleanupCopy.reason(item.reason))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = item.lastActivity, date > .distantPast {
                    Text(L10n.t("aitools.modified", date.formatted(.dateTime.year().month().day().locale(L10n.locale))))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if item.kind == .model, let count = Int(item.metadata["sharedBlobCount"] ?? ""), count > 0 {
                    Text(L10n.t("aitools.shared_blobs", count)).font(.caption2).foregroundStyle(.secondary)
                }
                if item.kind == .worktree {
                    Text(worktreeDetails(item)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(relative(item.path)).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).help(item.path).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if let tool = item.cliTool {
                Button(L10n.t("aitools.manage")) { cliTarget = tool }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.phase == .cleaning)
            } else {
                Text(item.resources.isEmpty ? "—" : (item.metadata["sizeComplete"] == "false" ? "≥ " : "") + AIToolCleanupCopy.bytes(Double(item.bytes)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: {
                Image(systemName: "magnifyingglass").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("diskmap.reveal"))
            .accessibilityLabel(L10n.t("aitools.reveal", item.title))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func groupSummary(_ group: AIToolCleanupGroup) -> String {
        if group.kind == .tool { return L10n.t("aitools.tools_shared", group.all.count) }
        if group.kind == .conversation {
            let range = group.visible.isEmpty && group.owner.map { model.age(for: $0) != .dontList } == true
                ? L10n.t("aitools.no_matching") : L10n.t("aitools.conversation_managed")
            return L10n.t("aitools.sessions_summary", group.all.count, AIToolCleanupCopy.bytes(Double(group.totalBytes)), group.visible.count) + " · " + range
        }
        if group.kind == .model && group.all.contains(where: { $0.reason == "modelGraphIncomplete" }) {
            return L10n.t("aitools.models_unverified", group.all.count)
        }
        return L10n.t("aitools.group_summary", group.selectable.count, group.all.count, AIToolCleanupCopy.bytes(Double(group.totalBytes)))
    }

    private var footer: some View {
        MDSelectionActionBar(selectedCount: model.selectedCount,
            selectedBytes: AIToolCleanupCopy.bytes(Double(model.selectedBytes)), canClean: model.canClean,
            progress: model.phase == .cleaning ? model.progress : nil,
            buttonIdentifier: "aitools.trash",
            action: {
                    guard model.canClean else { return }
                    confirmation = Confirmation(revision: model.previewRevision, items: model.selectedCandidates, resources: model.selectedResources)
            }) { EmptyView() }
    }

    private func confirmationSheet(_ frozen: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("aitools.confirm_title")).font(.title3.weight(.semibold))
            Text(L10n.t("aitools.confirm_body", frozen.items.count, AIToolCleanupCopy.bytes(Double(frozen.bytes))))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(frozen.resources, id: \.path) { resource in
                        HStack(alignment: .top) {
                            Text(relative(resource.path)).font(.caption).textSelection(.enabled)
                            Spacer()
                            Text(AIToolCleanupCopy.bytes(Double(resource.bytes))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(L10n.t("aitools.trash_note")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.t("common.cancel")) { confirmation = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.t("aitools.confirm_action")) {
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
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.t("aitools.result", AIToolCleanupCopy.bytes(Double(result.movedToTrashBytes))),
                  systemImage: result.errors.isEmpty ? "checkmark.circle" : "info.circle")
                .font(.callout.weight(.medium))
            if !result.errors.isEmpty {
                DisclosureGroup(L10n.t("aitools.failures", result.errors.count)) {
                    ForEach(Array(result.errors.prefix(20).enumerated()), id: \.offset) { _, error in
                        Text(AIToolCleanupCopy.reason(error)).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func relative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
    }
    private func worktreeDetails(_ item: AICleanupCandidate) -> String {
        guard item.metadata["gitStatus"] == "known" else { return L10n.t("aitools.git_unknown") }
        return L10n.t("aitools.git_status", Int(item.metadata["trackedChanges"] ?? "") ?? 0,
                      Int(item.metadata["untrackedFiles"] ?? "") ?? 0, Int(item.metadata["ignoredFiles"] ?? "") ?? 0)
    }
}

enum AIToolCleanupCopy {
    static func issueSection(_ raw: String) -> AIDataSection? {
        let code = raw.replacingOccurrences(of: "ai_cleanup_", with: "")
        if code.hasPrefix("model") { return .models }
        if code.hasPrefix("conversation_") { return .conversations }
        if code.hasPrefix("worktree_") { return .worktrees }
        return nil
    }
    static func bytes(_ value: Double) -> String { value == 0 ? "0 B" : Format.bytes(value) }
    static func reason(_ raw: String) -> String {
        let code = String(raw.split(separator: ":", maxSplits: 1).first ?? Substring(raw))
            .replacingOccurrences(of: "ai_cleanup_", with: "")
        let key = "aitools.reason." + code
        let value = L10n.t(key)
        if value != key { return value }
        return L10n.t("aitools.reason.default")
    }
    static func groupTitle(_ group: AIToolCleanupGroup) -> String {
        if let owner = group.owner, group.kind == .conversation { return L10n.t("aitools.group.conversation", owner.name) }
        return L10n.t("aitools.group." + group.kind.rawValue)
    }
}
