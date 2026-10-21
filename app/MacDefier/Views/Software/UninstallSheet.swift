import SwiftUI
import CleanupKit
import AppKit

struct UninstallSheet: View {
    let app: InstalledApp
    var onClose: () -> Void

    @State private var items: [ResidualItem] = []
    @State private var keepUserData = true
    @State private var phase: Phase = .loading
    @State private var result: CleanupResult?
    @State private var errorEntries: [UninstallErrorText.Entry] = []
    @State private var isWorking = false
    @State private var confirm = false
    @State private var confirmForceQuit = false
    @State private var loadError: String?

    private enum Phase {
        case loading, preview, working, done
    }

    private var selectedCount: Int { items.filter(\.isSelected).count }
    private var selectedBytes: UInt64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.bytes }
    }
    private var retainedItems: [ResidualItem] {
        items.filter { $0.kind != .appBundle && !$0.isSelected }
    }
    private var retainedBytes: UInt64 {
        retainedItems.reduce(0) { $0 + $1.bytes }
    }
    private var selectionSummaryTitle: String {
        guard selectedCount > 0 else { return L10n.t("cleanup.none_selected") }
        let hasApp = items.contains { $0.isSelected && $0.kind == .appBundle }
        let hasData = items.contains { $0.isSelected && $0.kind != .appBundle }
        if hasData {
            return AppLanguage.current.isEnglish
                ? (hasApp ? "App and selected data" : "Selected app data only")
                : (hasApp ? "应用及已选关联数据" : "仅处理已选关联数据")
        }
        return AppLanguage.current.isEnglish ? "App only" : "仅删除应用"
    }
    private var actionVerb: String {
        app.canTrashAppBundle ? L10n.t("uninstall.verb") : L10n.t("uninstall.verb_residual")
    }
    private var actionProgressText: String {
        app.canTrashAppBundle ? L10n.t("uninstall.working") : L10n.t("uninstall.working_residual")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView(L10n.t("uninstall.loading"))
                        Text(app.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if !app.canTrashAppBundle {
                            Text(L10n.t("uninstall.system_loading_note"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .preview:
                    previewBody
                case .working:
                    workingBody
                case .done:
                    doneBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if phase == .preview {
                Divider()
                footer
            } else if phase == .done {
                Divider()
                HStack {
                    Spacer()
                    Button(L10n.t("common.done")) { onClose() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        .frame(width: 640, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadResiduals()
        }
        .confirmationDialog(
            L10n.t("uninstall.confirm_title", actionVerb),
            isPresented: $confirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("uninstall.confirm_move", selectedCount), role: .destructive) {
                Task { await runUninstall() }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t(
                "uninstall.confirm_msg",
                selectedCount,
                Format.bytes(Double(selectedBytes)),
                app.canTrashAppBundle ? L10n.t("uninstall.confirm_with_main") : L10n.t("uninstall.confirm_no_main")
            ))
        }
        .confirmationDialog(
            L10n.t("uninstall.force_quit_title", app.name),
            isPresented: $confirmForceQuit,
            titleVisibility: .visible
        ) {
            Button(L10n.t("uninstall.force_quit_action"), role: .destructive) {
                Task { await runUninstall(forceQuitIfNeeded: true) }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("uninstall.force_quit_message"))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(actionVerb) \(app.name)")
                    .font(.system(size: 16, weight: .semibold))
                Text(app.bundleIdentifier)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                Text(app.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(L10n.t("uninstall.close")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            MDCheckbox(L10n.t("uninstall.keep_user_data"), isOn: Binding(
                get: { keepUserData },
                set: { keepUserData = $0; applyKeepUserData() }
            )) {
                Text(L10n.t("uninstall.keep_user_data"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityIdentifier("uninstall.keepUserData")

            uninstallModeSummary

            // 列表总占用 vs 本窗可勾项：对上才不「14GB 变 2GB」
            sizeReconcileBanner
                .padding(.horizontal, 16)

            if !app.canTrashAppBundle {
                Text(L10n.t("uninstall.system_note"))
                    .font(.system(size: 11))
                    .foregroundStyle(MDTheme.secondary)
                    .padding(.horizontal, 16)
            }

            HStack(spacing: 10) {
                Text(L10n.t("uninstall.selected_line", selectedCount, Format.bytes(Double(selectedBytes))))
                    .font(.system(size: 12))
                    .foregroundStyle(MDTheme.secondary)
                Spacer(minLength: 8)
                Button(L10n.t("common.select_all"), action: selectAllItems)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!items.contains { canBulkSelect($0) && !$0.isSelected })
                    .help(L10n.t("uninstall.select_all_help"))
                    .accessibilityIdentifier("uninstall.selectAll")
                Button(L10n.t("common.deselect_all"), action: clearItemSelection)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedCount == 0)
                    .accessibilityIdentifier("uninstall.deselectAll")
            }
            .padding(.horizontal, 16)

            ScrollView {
                MDGroupedList {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        residualRow(item, showSeparator: idx < items.count - 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    /// The safe default is intentionally not called a complete uninstall.  Show the
    /// retained size and paths before confirmation, especially for game containers.
    private var uninstallModeSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectionSummaryTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MDTheme.label)
            Text("本次将移入废纸篓 \(Format.bytes(Double(selectedBytes)))；将继续保留 \(Format.bytes(Double(retainedBytes))) 数据。")
                .font(.system(size: 11))
                .foregroundStyle(MDTheme.secondary)
            if let largest = retainedItems.max(by: { $0.bytes < $1.bytes }) {
                Text("保留：\(largest.path)（\(largest.kind.localizedTitle)，\(largest.formattedSize)）。可能包含游戏资源、设置或存档。")
                    .font(.system(size: 10))
                    .foregroundStyle(MDTheme.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if retainedItems.contains(where: { $0.path.contains("/Library/Group Containers/") }) {
                Text("共享 Group Container 不会自动处理；仍有其他 App 使用时必须保留。")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MDTheme.surfaceInset))
        .padding(.horizontal, 16)
    }

    /// 列表总占用 vs Sheet 内可勾项合计（解释「14GB→2GB」）
    @ViewBuilder private var sizeReconcileBanner: some View {
        let sheetTotal = items.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let listTotal = app.totalBytes
        let listLabel = Format.bytes(Double(listTotal))
        let sheetLabel = Format.bytes(Double(sheetTotal))
        let gap = listTotal > sheetTotal ? listTotal - sheetTotal : 0
        let close = gap < max(listTotal / 20, 50 * 1_048_576) // 5% 或 50MB 内视为对得上
        if !close {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(MDTheme.accent)
                    .font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLanguage.current.isEnglish
                         ? "List \(listLabel) · this sheet \(sheetLabel)"
                         : "列表 \(listLabel) · 本窗 \(sheetLabel)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MDTheme.label)
                    Text(AppLanguage.current.isEnglish
                         ? "Sheet only lists removable leftovers (app + related). Some list bulk may be shared/system paths not shown here."
                         : "本窗只列可勾选的主程序与关联残留；列表体积可能含共享/系统路径，不会全部出现在这里。")
                        .font(.system(size: 10))
                        .foregroundStyle(MDTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MDTheme.surfaceInset)
            )
        }
    }

    private func residualRow(_ item: ResidualItem, showSeparator: Bool) -> some View {
        MDListRowChrome(showSeparator: showSeparator, separatorLeading: 40, verticalPadding: MDTheme.rowVerticalPadding) {
            MDCheckbox(item.name, isOn: Binding(
                get: { item.isSelected },
                set: { newVal in
                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                        items[i].isSelected = newVal
                    }
                }
            )) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(MDTheme.label)
                                .lineLimit(1)
                            Text(item.kind.localizedTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(MDTheme.surfaceInset, in: Capsule())
                                .foregroundStyle(MDTheme.secondary)
                        }
                        Text(item.path)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(MDTheme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .mdCopyPathMenu(item.path)
                    }
                    Spacer(minLength: 8)
                    Text(item.formattedSize)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(MDTheme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(item.kind == .appBundle && !app.canTrashAppBundle)
            .help(item.note)
            .accessibilityIdentifier("uninstall.item.\(item.id)")
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.t("uninstall.show_finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            Spacer()
            Button(L10n.t("uninstall.cancel")) { onClose() }
            Button(isWorking ? L10n.t("uninstall.working") : (app.canTrashAppBundle ? L10n.t("uninstall.move_trash") : L10n.t("uninstall.verb_residual"))) {
                confirm = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCount == 0 || isWorking)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var workingBody: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView(actionProgressText)
            Text(L10n.t("uninstall.working_safety_hint"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneBody: some View {
        VStack(spacing: 14) {
            Spacer()
            let appGone = !FileManager.default.fileExists(atPath: app.path)
            let okCount = result?.cleanedCount ?? 0
            let hasErrors = !(result?.errors.isEmpty ?? true)
            // Residual-only / system app: success when selected work finished; require appGone only when we tried to trash main bundle
            let fullyOk: Bool = {
                if app.canTrashAppBundle {
                    return appGone && !hasErrors && okCount > 0
                }
                return !hasErrors && okCount > 0
            }()
            let partial = okCount > 0 && !fullyOk

            Image(systemName: fullyOk ? "checkmark.circle.fill" : (partial ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                .font(.system(size: 40))
                .foregroundStyle(fullyOk ? Color.green : (partial ? Color.orange : Color.red))

            Text(fullyOk ? L10n.t("uninstall.done_ok", actionVerb) : (partial ? L10n.t("uninstall.done_partial") : L10n.t("uninstall.done_fail")))
                .font(.system(size: 16, weight: .semibold))

            if let result {
                Text(L10n.t(
                    "uninstall.processed_to_trash",
                    result.cleanedCount,
                    Format.bytes(Double(result.movedToTrashBytes))
                ))
                    .foregroundStyle(.secondary)
                if app.canTrashAppBundle && appGone {
                    Text(L10n.t("uninstall.main_gone"))
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else if app.canTrashAppBundle {
                    Text(L10n.t("uninstall.main_still", app.path))
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Text(L10n.t("uninstall.system_kept"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !result.errors.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(errorEntries) { entry in
                                UninstallErrorRow(entry: entry)
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                    .frame(maxHeight: 160)
                }
                let retained = retainedItems.filter { item in
                    !result.trashedPaths.contains(item.path)
                        && FileManager.default.fileExists(atPath: item.path)
                }
                if let largest = retained.max(by: { $0.bytes < $1.bytes }) {
                    Text(L10n.t("uninstall.retained_data", Format.bytes(Double(retained.reduce(UInt64(0)) { $0 + $1.bytes }))))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                    Button(L10n.t("uninstall.show_retained_data")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: largest.path)])
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack(spacing: 12) {
                Button(L10n.t("uninstall.open_trash")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                }
                if !app.canTrashAppBundle || !FileManager.default.fileExists(atPath: app.path) {
                    // ok
                } else {
                    Button(L10n.t("uninstall.show_main")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadResiduals() async {
        phase = .loading
        loadError = nil
        let snapshot = app
        let found = await Task.detached(priority: .userInitiated) {
            ResidualPreview.findResiduals(for: snapshot)
        }.value
        items = app.canTrashAppBundle ? found : found.filter { $0.kind != .appBundle }
        applyKeepUserData()
        if items.isEmpty {
            if app.canTrashAppBundle {
                // at least the app itself
                items = [
                    ResidualItem(
                        path: app.path,
                        kind: .appBundle,
                        bytes: app.bytes,
                        isSelected: true,
                        note: L10n.t("uninstall.main_bundle")
                    )
                ]
            } else {
                loadError = L10n.t("uninstall.no_residual")
            }
        }
        phase = .preview
    }

    private func canBulkSelect(_ item: ResidualItem) -> Bool {
        if item.kind == .mediaLibrary || item.path.contains("/Library/Group Containers/") { return false }
        return item.kind != .appBundle || app.canTrashAppBundle
    }

    private func selectAllItems() {
        var updated = items
        for i in updated.indices where canBulkSelect(updated[i]) {
            updated[i].isSelected = true
        }
        if updated.contains(where: { $0.isSelected && [.preferences, .containers, .support, .mediaLibrary].contains($0.kind) }) {
            // Direct state assignment does not invoke the preset control's binding setter.
            keepUserData = false
        }
        items = updated
    }

    private func clearItemSelection() {
        var updated = items
        for i in updated.indices { updated[i].isSelected = false }
        items = updated
    }

    private func applyKeepUserData() {
        var updated = items
        for i in updated.indices {
            switch updated[i].kind {
            case .appBundle:
                // 可卸主程序默认勾；系统 App 列表里通常没有这一项
                updated[i].isSelected = app.canTrashAppBundle
            case .preferences, .containers, .support:
                // 保留用户数据=开 → 不勾；关掉开关 → 用户明确要清数据才勾
                // Group Containers may be shared: never bulk-select them.
                updated[i].isSelected = !keepUserData && !updated[i].path.contains("/Library/Group Containers/")
            case .mediaLibrary:
                // 照片/音乐/影片本体永不自动勾（执行器层也已硬拦截），只能逐项手选
                updated[i].isSelected = false
            case .cache, .logs, .savedState, .other:
                // 稳妥：不自动勾，用户手选
                if keepUserData {
                    updated[i].isSelected = false
                }
                // keepUserData 关时也不强勾缓存，避免误伤；仍手选
            }
        }
        items = updated
    }

    private func runUninstall(forceQuitIfNeeded: Bool = false) async {
        isWorking = true
        errorEntries = []
        phase = .working
        let snapshot = items
        let r = await SoftwareService.shared.uninstall(
            app: app,
            items: snapshot,
            forceQuitIfNeeded: forceQuitIfNeeded
        )
        if r.requiresForceQuit {
            result = nil
            phase = .preview
            isWorking = false
            confirmForceQuit = true
            return
        }
        errorEntries = await Task.detached(priority: .utility) {
            UninstallErrorText.entries(for: r.errors)
        }.value
        result = r
        phase = .done
        isWorking = false
    }
}
