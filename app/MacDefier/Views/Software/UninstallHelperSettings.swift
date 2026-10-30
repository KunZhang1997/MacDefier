import SwiftUI
import AppKit
import UninstallHelperClient

/// Registration is user-initiated; merely opening Settings never installs or
/// starts a privileged service. The status is refreshed after System Settings.
struct UninstallHelperSettings: View {
    @State private var state = UninstallHelperSetup.State.unavailable
    @State private var busy = false
    @State private var failure: [UninstallErrorText.Entry] = []

    private var statusKey: String {
        switch state {
        case .enabled: return "uninstall.helper.enabled"
        case .notRegistered: return "uninstall.helper.not_registered"
        case .requiresApproval: return "uninstall.helper.approval"
        case .unavailable: return "uninstall.helper.unavailable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t(statusKey))
                .font(.body)
            Text(L10n.t("uninstall.helper.scope"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if state == .enabled {
                    Button(L10n.t("uninstall.helper.disable")) { perform(disable: true) }
                } else {
                    Button(L10n.t("uninstall.helper.enable")) { perform(disable: false) }
                        .disabled(state == .unavailable)
                }
                if state == .requiresApproval {
                    Button(L10n.t("settings.open_system_settings")) { UninstallHelperSetup.openSystemSettings() }
                }
                if busy { ProgressView().controlSize(.small).accessibilityLabel(L10n.t("uninstall.helper.updating")) }
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            ForEach(failure) { UninstallErrorRow(entry: $0) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { state = UninstallHelperSetup.state }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state = UninstallHelperSetup.state
        }
    }

    private func perform(disable: Bool) {
        busy = true
        failure = []
        Task {
            do {
                if disable { try await UninstallHelperClient.shared.disable() }
                else { try await UninstallHelperClient.shared.enable() }
            } catch { failure = UninstallErrorText.entries(for: [error.localizedDescription]) }
            state = UninstallHelperSetup.state
            busy = false
        }
    }
}
