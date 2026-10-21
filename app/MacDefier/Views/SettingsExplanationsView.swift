// SettingsExplanationsView — long privacy / FDA / coverage copy (U3).

import SwiftUI

struct SettingsExplanationsView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("settings.explanations"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(L10n.t("settings.explanations_done")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(
                        title: L10n.t("settings.scan_permission"),
                        body: L10n.t("settings.fda_body") + "\n\n" + L10n.t("settings.coverage_body")
                    )
                    section(
                        title: L10n.t("settings.ai_privacy"),
                        body: L10n.t("settings.ai_privacy_body") + "\n\n" + L10n.t("settings.local_hint")
                    )
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 520)
        .background(MDTheme.content)
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MDTheme.label)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(MDTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MDTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous)
                        .stroke(MDTheme.border.opacity(0.55), lineWidth: 0.5)
                )
        }
    }
}
