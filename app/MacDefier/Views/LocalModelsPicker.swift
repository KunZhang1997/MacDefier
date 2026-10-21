import SwiftUI

struct LocalModelsPicker: View {
    @ObservedObject var manager: OllamaModelManager
    let endpoint: String
    let selectedModel: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customModel = ""

    private struct Choice: Identifiable {
        let name: String
        let title: String
        let approximateSize: String
        var id: String { name }
    }

    private var choices: [Choice] {
        let catalog = [
            Choice(name: "qwen3.5:0.8b", title: "Qwen3.5 · 0.8B", approximateSize: "≈1.3 GB"),
            Choice(name: "qwen3.5:2b", title: "Qwen3.5 · 2B", approximateSize: "≈3 GB"),
            Choice(name: "qwen3.5:4b", title: "Qwen3.5 · 4B", approximateSize: "≈4 GB")
        ]
        let extras = manager.models.filter { installed in
            !catalog.contains { OllamaEndpoint.matches($0.name, installed.name) }
        }.map { Choice(name: $0.name, title: $0.name, approximateSize: "") }
        return catalog + extras
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.t("settings.local_models"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { Task { await manager.refresh(endpoint: endpoint) } } label: {
                    Label(L10n.t("settings.local_refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing || manager.activeModel != nil)
                Button(L10n.t("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        modelRow(choice)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                TextField(L10n.t("settings.local_other_model"), text: $customModel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { selectCustomModel() }
                    .disabled(manager.activeModel != nil)
                Button(L10n.t("settings.local_download_use")) { selectCustomModel() }
                    .disabled(!OllamaEndpoint.validModelName(customModel.trimmingCharacters(in: .whitespacesAndNewlines))
                              || manager.activeModel != nil)
            }

            if let active = manager.activeModel,
               !choices.contains(where: { OllamaEndpoint.matches($0.name, active) }) {
                HStack {
                    Text(active).lineLimit(1)
                    Spacer()
                    Text(manager.stage.title).foregroundStyle(MDTheme.secondary)
                    Button(L10n.t("common.cancel")) { manager.cancel() }
                }
                downloadProgress
            }
            if let failure = manager.failure {
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(MDTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(failure.message)
            }
            Text(L10n.t("settings.local_download_hint"))
                .font(.caption)
                .foregroundStyle(MDTheme.secondary)
        }
        .padding(20)
        .frame(width: 480)
        .background(MDTheme.content)
        .task { await manager.refresh(endpoint: endpoint) }
    }

    private func modelRow(_ choice: Choice) -> some View {
        let installed = manager.installedName(choice.name)
        let selected = OllamaEndpoint.matches(selectedModel, installed ?? choice.name)
        let active = manager.activeModel.map { OllamaEndpoint.matches($0, choice.name) } ?? false
        let failed = manager.failedModel.map { OllamaEndpoint.matches($0, choice.name) } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.title).font(.body.weight(.medium))
                    Text(sizeLabel(choice, installed: installed))
                        .font(.caption)
                        .foregroundStyle(MDTheme.secondary)
                }
                Spacer(minLength: 12)
                if active {
                    Text(manager.stage.title).font(.caption).foregroundStyle(MDTheme.secondary)
                    Button(L10n.t("common.cancel")) { manager.cancel() }
                } else if selected, installed != nil {
                    Label(L10n.t("settings.local_using"), systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(MDTheme.success)
                } else {
                    Button(installed != nil ? L10n.t("settings.local_use")
                           : L10n.t(failed ? "settings.local_retry_use" : "settings.local_download_use")) {
                        onSelect(installed ?? choice.name)
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.activeModel != nil)
                    .accessibilityLabel(choice.title + ", " + L10n.t(installed != nil ? "settings.local_use" : "settings.local_download_use"))
                }
            }
            if active { downloadProgress }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private var downloadProgress: some View {
        if let fraction = manager.progress {
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .accessibilityLabel(manager.stage.title)
                Text(L10n.t("settings.local_current_file") + " " + fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
            }
        } else {
            ProgressView().controlSize(.small).accessibilityLabel(manager.stage.title)
        }
    }

    private func sizeLabel(_ choice: Choice, installed: String?) -> String {
        if let installed, let bytes = manager.models.first(where: { $0.name == installed })?.size {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return choice.approximateSize
    }

    private func selectCustomModel() {
        let name = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OllamaEndpoint.validModelName(name), manager.activeModel == nil else { return }
        onSelect(name)
    }
}

extension OllamaModelManager.Stage {
    var title: String {
        switch self {
        case .preparing: return L10n.t("settings.local_preparing")
        case .runtimeDownload: return L10n.t("settings.local_runtime_download")
        case .starting: return L10n.t("settings.local_starting")
        case .downloading: return L10n.t("settings.local_downloading")
        case .verifying: return L10n.t("settings.local_verifying")
        }
    }
}

extension OllamaModelFailure {
    var message: String {
        switch self {
        case .endpoint: return L10n.t("settings.local_endpoint_unsupported")
        case .unavailable, .runtimeStart: return L10n.t("settings.local_service_failed")
        case .runtimeChecksum: return L10n.t("settings.local_checksum_failed")
        case .runtimeDownload, .runtimeInstall: return L10n.t("settings.local_runtime_failed")
        case .http, .invalidResponse, .interrupted, .modelMissing: return L10n.t("settings.local_download_failed")
        }
    }
}
