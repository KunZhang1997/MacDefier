import AppKit
import SwiftUI

/// An independent introduction: never changes the page, selection or running task.
struct UsageGuideOverlay: View {
    @ObservedObject var guide: UsageGuideState
    var onOpenSettings: () -> Void
    @AppStorage(PetSkinStore.appStorageKey) private var skinRaw = PetSkinStore.defaultSkin.rawValue
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var primaryFocused: Bool
    @State private var fdaOpenFailed = false

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                header
                ScrollView {
                    page(compact: geometry.size.height < 560)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .id(guide.step)
                footer
            }
            .padding(24)
            .frame(width: min(600, max(0, geometry.size.width - 40)),
                   height: min(480, max(0, geometry.size.height - 40)))
            .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(MDTheme.subtleBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.20).ignoresSafeArea())
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("usageGuide")
        .onAppear { headingFocused = true; primaryFocused = true }
        .onChange(of: guide.step) { _, _ in headingFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(L10n.t("guide.\(pageKey).title"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(MDTheme.label)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Spacer(minLength: 0)
                Text("\(guide.step.rawValue + 1) / \(UsageGuideStep.allCases.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(MDTheme.secondary)
                    .fixedSize()
                    .accessibilityLabel(L10n.t("guide.step", guide.step.rawValue + 1, UsageGuideStep.allCases.count))
            }
            Text(L10n.t("guide.\(pageKey).subtitle"))
                .font(.body)
                .foregroundStyle(MDTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageKey: String {
        switch guide.step {
        case .welcome: return "welcome"
        case .scan: return "scan"
        case .review: return "review"
        case .setup: return "setup"
        case .ready: return "ready"
        }
    }

    @ViewBuilder private func page(compact: Bool) -> some View {
        switch guide.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    feature("trash", "cleanup")
                    feature("archivebox", "aiTools")
                    feature("internaldrive", "disk")
                    feature("square.grid.2x2", "software")
                }
                Label(L10n.t("guide.welcome.monitor"), systemImage: "waveform.path.ecg")
                    .font(.body).foregroundStyle(MDTheme.secondary)
            }
        case .scan:
            VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                Image("ScanCleanupTray")
                    .resizable().scaledToFit().frame(height: compact ? 70 : 110)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                instruction("hand.tap", "scan.start")
                instruction("sidebar.left", "scan.types")
                instruction("pause.circle", "scan.control")
            }
        case .review:
            VStack(alignment: .leading, spacing: 18) {
                instruction("checkmark.square", "review.select")
                instruction("trash", "review.confirm")
                instruction("lock", "review.keep")
            }
        case .setup:
            VStack(alignment: .leading, spacing: 20) {
                instruction("externaldrive.badge.checkmark", "setup.permissions")
                Button {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
                        fdaOpenFailed = true
                        return
                    }
                    fdaOpenFailed = !NSWorkspace.shared.open(url)
                } label: {
                    Label(L10n.t("guide.open_full_disk_access"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("usageGuide.openFullDiskAccess")
                if fdaOpenFailed {
                    Text(L10n.t("guide.full_disk_open_failed"))
                        .font(.callout)
                        .foregroundStyle(MDTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                instruction("sparkles", "setup.ai")
                Button(action: onOpenSettings) {
                    Label(L10n.t("guide.open_settings"), systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("usageGuide.settings")
            }
        case .ready:
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                DefierPetView(skin: PetSkin(rawValue: skinRaw) ?? PetSkinStore.defaultSkin,
                              size: compact ? 70 : 100, tracksLook: false, animates: false, onTap: {})
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false).accessibilityHidden(true)
                instruction("hand.draw", "ready.pet")
                instruction("questionmark.circle", "ready.replay")
            }
        }
    }

    private func feature(_ symbol: String, _ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 21))
                .foregroundStyle(MDTheme.secondary).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.t("guide.feature.\(key).title"))
                    .font(.headline)
                    .foregroundStyle(MDTheme.label)
                Text(L10n.t("guide.feature.\(key).detail"))
                    .font(.body).foregroundStyle(MDTheme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(MDTheme.content, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func instruction(_ symbol: String, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19))
                .foregroundStyle(MDTheme.secondary).frame(width: 25, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.t("guide.\(key).title"))
                    .font(.headline).foregroundStyle(MDTheme.label)
                Text(L10n.t("guide.\(key).detail"))
                    .font(.body).foregroundStyle(MDTheme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Divider()
            HStack(spacing: 12) {
                if guide.step != .welcome {
                    Button(L10n.t("guide.back")) { guide.back() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("usageGuide.back")
                }
                Button(L10n.t("guide.skip")) { guide.dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("usageGuide.skip")
                Spacer(minLength: 0)
                Button(L10n.t(guide.step == .ready ? "guide.finish" : "guide.next")) { guide.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .focused($primaryFocused)
                    .accessibilityIdentifier("usageGuide.next")
            }
            .controlSize(.large)
        }
    }
}
