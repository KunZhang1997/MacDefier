// CleanupConfirmSheet — 可滚动确认：列出实际将处理的全部路径；永久清空与移入废纸篓分区。

import SwiftUI
import CleanupKit

struct CleanupConfirmSheet: View {
    let revocableItems: [CleanableItem]
    let permanentItems: [CleanableItem]
    let revocablePaths: [String]
    let permanentPaths: [String]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var revocableBytes: UInt64 {
        revocableItems.reduce(0) { $0 + $1.bytes }
    }

    private var permanentBytes: UInt64 {
        permanentItems.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        let revocableTotal = revocableBytes
        let permanentTotal = permanentBytes
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !revocableItems.isEmpty {
                        section(
                            title: L10n.t("cleanup.confirm.section_trash"),
                            subtitle: L10n.t(
                                "cleanup.confirm.section_trash_sub",
                                revocablePaths.count,
                                Format.bytes(Double(revocableTotal))
                            ),
                            warning: false,
                            paths: revocablePaths
                        )
                    }
                    if !permanentItems.isEmpty {
                        section(
                            title: L10n.t("cleanup.confirm.section_empty"),
                            subtitle: L10n.t(
                                "cleanup.confirm.section_empty_sub",
                                permanentPaths.count,
                                Format.bytes(Double(permanentTotal))
                            ),
                            warning: true,
                            paths: permanentPaths
                        )
                    }
                    if revocableItems.isEmpty && permanentItems.isEmpty {
                        Text(L10n.t("cleanup.none_selected"))
                            .foregroundStyle(MDTheme.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 360)

            Divider()

            HStack {
                Spacer()
                Button(L10n.t("common.cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmActionTitle, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(revocableItems.isEmpty && permanentItems.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 280)
    }

    private var title: String {
        if !permanentItems.isEmpty, revocableItems.isEmpty {
            return L10n.t("cleanup.confirm.empty_title")
        }
        if !permanentItems.isEmpty {
            return L10n.t("cleanup.confirm.mixed_title")
        }
        return L10n.t("cleanup.confirm.trash_title")
    }

    private var confirmActionTitle: String {
        if !permanentItems.isEmpty, revocableItems.isEmpty {
            return L10n.t("cleanup.confirm.empty_action")
        }
        if !permanentItems.isEmpty {
            return L10n.t("cleanup.confirm.mixed_action")
        }
        return L10n.t("cleanup.confirm.trash_action")
    }

    private func section(
        title: String,
        subtitle: String,
        warning: Bool,
        paths: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(warning ? MDTheme.warning : MDTheme.label)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(MDTheme.secondary)
            if warning {
                Text(L10n.t("cleanup.confirm.empty_warn"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MDTheme.warning)
            }
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(paths.indices, id: \.self) { index in
                    Text(homeRelative(paths[index]))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(MDTheme.secondary)
                        .mdCopyPathMenu(paths[index])
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let n = (path as NSString).standardizingPath
        if n.hasPrefix(home + "/") {
            return "~/" + String(n.dropFirst(home.count + 1))
        }
        return n
    }
}
