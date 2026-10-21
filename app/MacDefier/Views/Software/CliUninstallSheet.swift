import SwiftUI
import CleanupKit
import AppKit

/// CLI tool uninstall preview (§7.3.1 C1).
struct CliUninstallSheet: View {
    let tool: CliTool
    var onClose: () -> Void

    @State private var stopAgents = false
    @State private var uninstallProgram = false
    @State private var selectedData: Set<String> = []
    @State private var phase: Phase = .preview
    @State private var result: CliUninstallResult?
    @State private var errorEntries: [UninstallErrorText.Entry] = []
    @State private var confirm = false

    private enum Phase {
        case preview, working, done
    }

    private var canUninstall: Bool { !tool.protected }

    /// Hermes is uninstallable but deserves a loud warning (not a hard lock).
    private var isHermesSensitive: Bool {
        let blob = (tool.packageId + " " + tool.displayName + " " + tool.detail).lowercased()
        return blob.contains("hermes")
    }

    private var hasProgram: Bool {
        switch tool.channel {
        case .npm, .brew, .uv:
            return !tool.packageId.isEmpty
        case .manual, .unknown:
            // Real install tree only — LaunchAgent alone is not "program"
            return tool.programPaths.contains { FileManager.default.fileExists(atPath: $0) }
        }
    }

    private var selectedDataBytes: UInt64 {
        tool.dataDirs.filter { selectedData.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    private var estimatedBytes: UInt64 {
        var n: UInt64 = 0
        if uninstallProgram && hasProgram { n += tool.programBytes }
        n += selectedDataBytes
        return n
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch phase {
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
        .onAppear {
            // Data off by default
            selectedData = []
            stopAgents = canUninstall && !tool.agents.isEmpty
            uninstallProgram = canUninstall && hasProgram
        }
        .confirmationDialog(
            isHermesSensitive
                ? L10n.t("cli.uninstall.hermes_confirm_title")
                : L10n.t("cli.uninstall.confirm_title"),
            isPresented: $confirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("cli.uninstall.confirm_action"), role: .destructive) {
                Task { await run() }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(
                isHermesSensitive
                    ? L10n.t(
                        "cli.uninstall.hermes_confirm_msg",
                        tool.displayName,
                        Format.bytes(Double(estimatedBytes))
                    )
                    : L10n.t(
                        "cli.uninstall.confirm_msg",
                        tool.displayName,
                        Format.bytes(Double(estimatedBytes))
                    )
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MDTheme.surface)
                    .frame(width: 40, height: 40)
                Image(systemName: "terminal")
                    .foregroundStyle(MDTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("cli.uninstall.title", tool.displayName))
                    .font(.system(size: 16, weight: .semibold))
                Text("\(tool.channel.localizedTitle) · \(tool.packageId)")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                if !tool.detail.isEmpty {
                    Text(tool.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(L10n.t("common.close")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var previewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if tool.protected {
                    Text(L10n.t("cli.uninstall.protected_body"))
                        .font(.system(size: 13))
                        .foregroundStyle(MDTheme.warning)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MDTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    if isHermesSensitive {
                        Text(L10n.t("cli.uninstall.hermes_warn"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MDTheme.warning)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(MDTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button(L10n.t("common.select_all"), action: selectAllOptions)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canUninstall || allOptionsSelected || !hasOptions)
                        .help(L10n.t("cli.uninstall.select_all_help"))
                        .accessibilityIdentifier("cliUninstall.selectAll")
                    Button(L10n.t("common.deselect_all"), action: clearAllOptions)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canUninstall || (!stopAgents && !uninstallProgram && selectedData.isEmpty))
                        .accessibilityIdentifier("cliUninstall.deselectAll")
                }

                if !tool.agents.isEmpty {
                    sectionCard(title: L10n.t("cli.uninstall.section_agents")) {
                        MDCheckbox(L10n.t("cli.uninstall.stop_agents"), isOn: $stopAgents) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.t("cli.uninstall.stop_agents"))
                                    .font(.system(size: 13, weight: .medium))
                                Text(tool.agents.map(\.label).joined(separator: ", "))
                                    .font(.system(size: 11).monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(!canUninstall)
                        .accessibilityIdentifier("cliUninstall.stopAgents")
                    }
                }

                if hasProgram {
                    sectionCard(title: L10n.t("cli.uninstall.section_program")) {
                        MDCheckbox(L10n.t("cli.uninstall.program_row", tool.channel.localizedTitle), isOn: $uninstallProgram) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.t("cli.uninstall.program_row", tool.channel.localizedTitle))
                                    .font(.system(size: 13, weight: .medium))
                                Text(L10n.t("cli.uninstall.program_size", tool.formattedProgramSize))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(commandPreview)
                                    .font(.system(size: 10).monospaced())
                                    .foregroundStyle(.tertiary)
                                    .mdCopyPathMenu(commandPreview)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(!canUninstall)
                        .accessibilityIdentifier("cliUninstall.program")
                    }
                }

                if !tool.dataDirs.isEmpty {
                    sectionCard(title: L10n.t("cli.uninstall.section_data")) {
                        Text(L10n.t("cli.uninstall.data_hint"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(tool.dataDirs) { dir in
                            MDCheckbox(dir.path, isOn: Binding(
                                get: { selectedData.contains(dir.path) },
                                set: { on in
                                    if on { selectedData.insert(dir.path) }
                                    else { selectedData.remove(dir.path) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dir.path)
                                        .font(.system(size: 12).monospaced())
                                        .lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(dir.bytes), countStyle: .file))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .disabled(!canUninstall)
                            .accessibilityIdentifier("cliUninstall.data.\(dir.path)")
                        }
                    }
                }

                Text(L10n.t("cli.uninstall.footer_trash"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private var hasOptions: Bool {
        !tool.agents.isEmpty || hasProgram || !tool.dataDirs.isEmpty
    }

    private var allOptionsSelected: Bool {
        (tool.agents.isEmpty || stopAgents)
            && (!hasProgram || uninstallProgram)
            && Set(tool.dataDirs.map(\.path)).isSubset(of: selectedData)
    }

    private func selectAllOptions() {
        guard canUninstall else { return }
        stopAgents = !tool.agents.isEmpty
        uninstallProgram = hasProgram
        selectedData = Set(tool.dataDirs.map(\.path))
    }

    private func clearAllOptions() {
        stopAgents = false
        uninstallProgram = false
        selectedData.removeAll()
    }

    private var commandPreview: String {
        switch tool.channel {
        case .npm:
            return "npm uninstall -g \(tool.packageId)"
        case .brew:
            return "brew uninstall \(tool.packageId)"
        case .uv:
            return "uv tool uninstall \(tool.packageId)"
        case .manual, .unknown:
            if !tool.programPaths.isEmpty {
                return "trash " + tool.programPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            }
            if !tool.agents.isEmpty {
                return "launchctl bootout + trash plist"
            }
            return "—"
        }
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MDTheme.border, lineWidth: 0.5)
                )
        }
    }

    private var workingBody: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView(L10n.t("cli.uninstall.working"))
            Text(tool.displayName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var doneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let result {
                    let failed = !result.errors.isEmpty
                    let madeProgress = result.programUninstalled || result.agentsStopped > 0 || !result.trashedPaths.isEmpty
                    Label(
                        failed ? L10n.t(madeProgress ? "cli.uninstall.done_partial" : "cli.uninstall.done_fail") : L10n.t("cli.uninstall.done_ok"),
                        systemImage: failed ? (madeProgress ? "exclamationmark.triangle.fill" : "xmark.octagon.fill") : "checkmark.circle.fill"
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(failed ? (madeProgress ? MDTheme.warning : MDTheme.danger) : .green)

                    Text(L10n.t(
                        "cli.uninstall.done_summary_split",
                        result.agentsStopped,
                        result.programUninstalled ? L10n.t("common.yes") : L10n.t("common.no"),
                        Format.bytes(Double(result.freedBytes)),
                        Format.bytes(Double(result.movedToTrashBytes))
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    if !result.errors.isEmpty {
                        Text(L10n.t("cli.uninstall.errors"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MDTheme.danger)
                        ForEach(errorEntries) { entry in
                            UninstallErrorRow(entry: entry, tint: MDTheme.danger)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Text(L10n.t("cli.uninstall.selected_line", Format.bytes(Double(estimatedBytes))))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("common.cancel")) { onClose() }
            Button(L10n.t("software.uninstall")) {
                confirm = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canUninstall || (!stopAgents && !uninstallProgram && selectedData.isEmpty))
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func run() async {
        phase = .working
        errorEntries = []
        let opts = CliUninstallOptions(
            stopAgents: stopAgents && !tool.agents.isEmpty,
            uninstallProgram: uninstallProgram && hasProgram,
            trashDataDirs: !selectedData.isEmpty,
            selectedDataPaths: Array(selectedData)
        )
        let toolCopy = tool
        let r = await Task.detached(priority: .userInitiated) {
            await CliUninstallExecutor.uninstall(tool: toolCopy, options: opts)
        }.value
        errorEntries = await Task.detached(priority: .utility) {
            UninstallErrorText.entries(for: r.errors)
        }.value
        result = r
        phase = .done
    }
}
