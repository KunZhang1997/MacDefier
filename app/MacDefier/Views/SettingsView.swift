import AppKit
import SwiftUI
import MonitorKit
import PetArchiveKit

/// 设置：每行底部分隔线（最后一行除外）；云端/本地切换；云端多配置弹窗
struct SettingsView: View {
    @State private var showMenuBar = UserDefaults.standard.object(forKey: MenuBarController.defaultsKey) as? Bool ?? true
    @AppStorage(MenuBarController.showCPUKey) private var menuBarShowCPU = false
    @AppStorage(MenuBarController.showRAMKey) private var menuBarShowRAM = false
    @State private var launchAtLogin = LaunchAtLogin.toggleIsOn
    @State private var launchAtLoginHint = ""

    @State private var aiEnabled = true
    @State private var aiUseCloud = true
    @State private var apiKey = ""
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var cloudModel = "gpt-4o-mini"
    @State private var localEndpoint = "http://127.0.0.1:11434/v1"
    @State private var localModel = ""
    @StateObject private var localModels = OllamaModelManager.shared
    @State private var showLocalModels = false
    @State private var showLocalAdvanced = false
    @State private var defaultIntensity = AIIntensity.standard
    @State private var cloudProfiles: [AICloudProfile] = []
    @State private var activeCloudProfileId: String?
    @State private var aiTestResult = ""
    @State private var aiTesting = false
    @State private var aiSavedHint = ""
    @State private var showCloudSheet = false
    @State private var showCloudPrivacyConfirm = false
    /// `true` when the privacy sheet was raised for a LAN endpoint while the
    /// segmented control is still in Local mode.  The generic sheet must not
    /// silently switch that configuration to Cloud.
    @State private var privacyPromptForLANEndpoint = false
    /// 保存成功后仍展示 LAN HTTP 风险（勿被 settings.saved 单独覆盖）
    @State private var lanHTTPRiskPending = false
    @State private var showDeleteAPIKeyConfirm = false
    @State private var showExplanations = false
    @State private var petImportTask: Task<Void, Never>?
    @State private var isPetImporting = false
    @State private var pendingPetPackRemoval: PetPack?

    @AppStorage(PetSkinStore.appStorageKey) private var petSkinRaw: String = PetSkinStore.defaultSkin.rawValue
    /// 用户是否已确认过「云端 AI 会发送摘要」
    @State private var cloudPrivacyAcknowledged = false
    /// 监控：公网 IP / 归属地查询（ipify + geojs / ipwhois 等回退）
    /// 默认关：公网 IP 属可选联网，需用户主动打开（审查 F07-1）
    @AppStorage(NetworkUsageSampler.publicIPLookupDefaultsKey) private var publicIPLookupEnabled = false
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw: String = AppLanguage.systemPreferred.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @ObservedObject private var petPackStore = PetPackStore.shared
    @State private var petPackHint = ""

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRaw) ?? .chinese },
            set: { appLanguageRaw = $0.rawValue }
        )
    }

    private var appAppearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsGroup(L10n.t("settings.general")) {
                    settingsRow(L10n.t("settings.menubar"), showLine: true) {
                        Toggle("", isOn: $showMenuBar)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: showMenuBar) { _, on in
                                MenuBarController.shared.setEnabled(on)
                            }
                    }
                    if showMenuBar {
                        // 菜单栏 icon 实时预览（不是把 General 当 icon 页）
                        TimelineView(.periodic(from: .now, by: 5)) { _ in
                            menuBarIconPreviewRow
                        }
                        settingsRow(L10n.t("settings.menubar_cpu"), showLine: true) {
                            Toggle("", isOn: $menuBarShowCPU)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .onChange(of: menuBarShowCPU) { _, _ in
                                    MenuBarController.shared.refreshFromDefaults()
                                }
                        }
                        settingsRow(L10n.t("settings.menubar_ram"), showLine: true) {
                            Toggle("", isOn: $menuBarShowRAM)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .onChange(of: menuBarShowRAM) { _, _ in
                                    MenuBarController.shared.refreshFromDefaults()
                                }
                        }
                    }
                    settingsRow(L10n.t("settings.launch_at_login"), showLine: true) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Toggle("", isOn: $launchAtLogin)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .onChange(of: launchAtLogin) { _, on in
                                    let result = LaunchAtLogin.setEnabled(on)
                                    if !result.ok {
                                        // 失败立即回滚 Toggle
                                        launchAtLogin = LaunchAtLogin.toggleIsOn
                                        launchAtLoginHint = result.error ?? L10n.t("settings.launch_failed")
                                    } else {
                                        launchAtLogin = LaunchAtLogin.toggleIsOn
                                        launchAtLoginHint = ""
                                    }
                                    if result.status == .requiresApproval {
                                        launchAtLoginHint = L10n.t("settings.launch_needs_approval")
                                    }
                                }
                            if LaunchAtLogin.status == .requiresApproval || !launchAtLoginHint.isEmpty {
                                Text(launchAtLoginHint.isEmpty
                                     ? L10n.t("settings.launch_needs_approval")
                                     : launchAtLoginHint)
                                    .font(.system(size: 10))
                                    .foregroundStyle(MDTheme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                                if LaunchAtLogin.status == .requiresApproval {
                                    Button(L10n.t("settings.launch_open_settings")) {
                                        LaunchAtLogin.openLoginItemsSettings()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                    settingsRow(L10n.t("settings.appearance"), showLine: true) {
                        Picker("", selection: appAppearanceBinding) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.settingsTitle).tag(appearance)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        // AppKit-backed pickers retain their menu labels across language changes.
                        .id(appLanguageRaw)
                    }
                    settingsRow(L10n.t("settings.language"), showLine: false) {
                        Picker("", selection: appLanguageBinding) {
                            // v0.1：中文 + English；其余语种 v0.2
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.settingsTitle).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }

                settingsGroup(L10n.t("settings.scan_permission")) {
                    settingsRow(L10n.t("settings.fda"), showLine: true) {
                        Button(L10n.t("settings.open_system_settings")) { openFDASettings() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    settingsRow(L10n.t("settings.residual_match"), showLine: false) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MDTheme.success)
                    }
                }

                settingsGroup(L10n.t("settings.ai_privacy")) {
                    settingsRow(L10n.t("settings.public_ip"), showLine: true) {
                        Toggle("", isOn: $publicIPLookupEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: publicIPLookupEnabled) { _, on in
                                // 关闭：取消查询 + generation；清内存/磁盘发布态
                                MonitorService.shared.applyPublicIPLookupPreference(enabled: on)
                            }
                    }

                    settingsRow(L10n.t("settings.enable_ai"), showLine: true) {
                        Toggle("", isOn: $aiEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: aiEnabled) { _, on in
                                if on, aiUseCloud, hasNewCloudCredential, !cloudPrivacyAcknowledged {
                                    privacyPromptForLANEndpoint = false
                                    showCloudPrivacyConfirm = true
                                } else {
                                    saveAI()
                                }
                            }
                    }
                    settingsRow(L10n.t("settings.mode"), showLine: true) {
                        Picker("", selection: $aiUseCloud) {
                            Text(L10n.t("settings.mode_cloud")).tag(true)
                            Text(L10n.t("settings.mode_local")).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                        .onChange(of: aiUseCloud) { _, useCloud in
                            localModels.cancel()
                            if useCloud, aiEnabled, hasNewCloudCredential, !cloudPrivacyAcknowledged {
                                privacyPromptForLANEndpoint = false
                                showCloudPrivacyConfirm = true
                            } else {
                                saveAI()
                            }
                        }
                    }

                    if aiUseCloud {
                        settingsRow(L10n.t("settings.api_config"), showLine: true) {
                            HStack(spacing: 8) {
                                Button { showCloudSheet = true } label: {
                                    HStack(spacing: 6) {
                                        Text(activeCloudSummary)
                                            .font(.system(size: 12))
                                            .foregroundStyle(MDTheme.secondary)
                                            .lineLimit(1)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(MDTheme.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                if !apiKey.isEmpty {
                                    Button(L10n.t("settings.api_delete_key"), role: .destructive) {
                                        showDeleteAPIKeyConfirm = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                        }
                    } else {
                        settingsRow(L10n.t("settings.model"), showLine: true) {
                            Button { showLocalModels = true } label: {
                                HStack(spacing: 6) {
                                    Text(localModel.isEmpty ? L10n.t("settings.local_choose") : localModel)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.right")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        if let active = localModels.activeModel {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(active + " · " + localModels.stage.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Button(L10n.t("common.cancel")) { localModels.cancel() }
                                    .controlSize(.small)
                            }
                            .padding(.vertical, 6)
                        }
                        if let failure = localModels.failure {
                            Button(failure.message) { showLocalModels = true }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(MDTheme.warning)
                        }
                        DisclosureGroup(L10n.t("settings.local_advanced"), isExpanded: $showLocalAdvanced) {
                            settingsRow("Endpoint", showLine: true) {
                                TextField("http://127.0.0.1:11434/v1", text: $localEndpoint)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 260)
                                    .onSubmit { saveAI() }
                            }
                            settingsRow(L10n.t("settings.model"), showLine: false) {
                                TextField(L10n.t("settings.model_placeholder"), text: $localModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 260)
                                    .onSubmit { saveAI() }
                            }
                        }
                        .font(.callout)
                        .padding(.vertical, 8)
                        .disabled(localModels.activeModel != nil)
                    }

                    settingsRow(L10n.t("settings.intensity"), showLine: true) {
                        Picker("", selection: $defaultIntensity) {
                            ForEach(AIIntensity.allCases) { i in
                                Text(i.title).tag(i)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        .id(appLanguageRaw)
                    }
                    settingsRow(L10n.t("settings.actions"), showLine: false) {
                        HStack(spacing: 6) {
                            Button(L10n.t("common.save")) { saveAI() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button(aiTesting ? "…" : L10n.t("settings.test")) {
                                Task { await testAI() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(aiTesting)
                            if !aiSavedHint.isEmpty {
                                Text(aiSavedHint)
                                    .font(.system(size: 12))
                                    .foregroundStyle(MDTheme.success)
                            }
                        }
                    }
                }

                // 说明与隐私：整页只保留一处，整行可点
                settingsGroup("") {
                    settingsLinkRow(L10n.t("settings.explanations")) {
                        showExplanations = true
                    }
                }

                if !aiTestResult.isEmpty {
                    Text(aiTestResult)
                        .font(.system(size: 12))
                        .foregroundStyle(aiTestResult.hasPrefix(L10n.t("settings.test_ok_prefix")) || aiTestResult.lowercased().hasPrefix("ok") || aiTestResult.hasPrefix("Connected") ? MDTheme.success : MDTheme.warning)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }

                // 宠物：双卡选肤 + 显眼导入入口 + 已导入列表
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.t("settings.pet"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MDTheme.label)
                        Spacer()
                        Button {
                            if isPetImporting {
                                petImportTask?.cancel()
                            } else {
                                importPetPack()
                            }
                        } label: {
                            Label(
                                isPetImporting ? L10n.t("common.cancel") : L10n.t("settings.import_pet"),
                                systemImage: isPetImporting ? "xmark" : "square.and.arrow.down"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    // Built-in + imported packs share the same list style; built-in preview is slightly larger.
                    VStack(spacing: 0) {
                        ForEach(PetSkin.allCases) { skin in
                            builtInPetRow(skin: skin, showLine: skin != PetSkin.allCases.last || !petPackStore.packs.isEmpty)
                        }
                        ForEach(Array(petPackStore.packs.enumerated()), id: \.element.id) { idx, pack in
                            petPackVisualRow(
                                pack,
                                showLine: idx < petPackStore.packs.count - 1
                            )
                        }
                    }
                    .background(MDTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous)
                            .stroke(MDTheme.border.opacity(0.55), lineWidth: 0.5)
                    )

                    if !petPackHint.isEmpty {
                        Text(petPackHint)
                            .font(.system(size: 12))
                            .foregroundStyle(petPackHint.hasPrefix(L10n.t("settings.pet_fail_prefix")) || petPackHint.hasPrefix("Failed") ? MDTheme.danger : MDTheme.accent)
                    }
                }
                .onAppear { petPackStore.reload() }
                .onDisappear { petImportTask?.cancel() }

                settingsGroup(L10n.t("settings.about")) {
                    settingsRow(L10n.t("settings.version"), showLine: true) {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(MDTheme.secondary)
                    }
                    settingsRow(L10n.t("settings.email"), showLine: false) {
                        Link("Kunzhang1997@outlook.com", destination: URL(string: "mailto:Kunzhang1997@outlook.com")!)
                            .font(.system(size: 12))
                            .foregroundStyle(MDTheme.accent)
                            .accessibilityHint(L10n.t("settings.email_hint"))
                    }
                }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, MDTheme.pagePadding)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MDTheme.content)
        .onChange(of: appLanguageRaw) { _, _ in
            // These are transient rendered messages, not saved settings or form drafts.
            aiSavedHint = ""
            aiTestResult = aiTesting ? L10n.t("settings.testing") : ""
            petPackHint = ""
            launchAtLoginHint = LaunchAtLogin.status == .requiresApproval
                ? L10n.t("settings.launch_needs_approval") : ""
        }
        .onChange(of: localEndpoint) { old, new in
            if old != new { localModels.cancel() }
        }
        .onAppear {
            loadAI()
            // 页面出现时重新读取登录项状态
            launchAtLogin = LaunchAtLogin.toggleIsOn
            if LaunchAtLogin.status == .requiresApproval {
                launchAtLoginHint = L10n.t("settings.launch_needs_approval")
            }
        }
        .sheet(isPresented: $showLocalModels) {
            LocalModelsPicker(manager: localModels, endpoint: localEndpoint,
                              selectedModel: localModel, onSelect: selectLocalModel)
        }
        // 云配置 Sheet 用独立 draft；取消不落盘、不 loadAI 覆盖草稿
        .sheet(isPresented: $showCloudSheet) {
            CloudProfilesSheet(
                initialProfiles: cloudProfiles,
                initialActiveId: activeCloudProfileId,
                privacyAlreadyAcknowledged: cloudPrivacyAcknowledged
            ) { result in
                showCloudSheet = false
                switch result {
                case .cancelled:
                    // 取消：不写盘、不改 Key；刷新仅同步已落盘状态
                    loadAI()
                case .saved(let profiles, let activeId, let acknowledged):
                    cloudProfiles = profiles
                    activeCloudProfileId = activeId
                    if let p = profiles.first(where: { $0.id == activeId }) ?? profiles.first {
                        baseURL = p.baseURL
                        cloudModel = p.model
                        apiKey = p.apiKey
                    }
                    if acknowledged {
                        cloudPrivacyAcknowledged = true
                    }
                    // 一次保存：Profile + Key + acknowledged
                    let ok = AISettingsStore.save(currentAISettings())
                    aiSavedHint = ok ? L10n.t("settings.saved") : L10n.t("settings.keychain_save_failed")
                    if ok {
                        loadAI()
                        NotificationCenter.default.post(name: .macDefierAISettingsDidChange, object: nil)
                    }
                    // 失败：保留界面 draft（cloudProfiles 已是用户编辑结果）供重试
                }
            }
        }
        .sheet(isPresented: $showExplanations) {
            SettingsExplanationsView {
                showExplanations = false
            }
        }
        .confirmationDialog(
            L10n.t("settings.cloud_confirm_title"),
            isPresented: $showCloudPrivacyConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.cloud_confirm_ok")) {
                cloudPrivacyAcknowledged = true
                aiEnabled = true
                // Preserve the user's selected mode.  For a LAN endpoint the
                // summary acknowledges that data leaves this Mac, but the
                // endpoint remains in the Local/LAN configuration slot.
                saveAI()
            }
            Button(L10n.t("settings.cloud_confirm_local"), role: .cancel) {
                if privacyPromptForLANEndpoint {
                    // Keep the unsaved LAN draft visible; do not recurse into
                    // saveAI and immediately present the same confirmation.
                    aiSavedHint = L10n.t("settings.not_saved")
                } else {
                    aiUseCloud = false
                    if aiEnabled { saveAI() }
                }
                privacyPromptForLANEndpoint = false
            }
            Button(L10n.t("settings.cloud_confirm_off"), role: .destructive) {
                aiEnabled = false
                privacyPromptForLANEndpoint = false
                saveAI()
            }
        } message: {
            Text(L10n.t("settings.cloud_confirm_body"))
        }
        .confirmationDialog(
            L10n.t("settings.api_delete_key_title"),
            isPresented: $showDeleteAPIKeyConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.api_delete_key"), role: .destructive) {
                deleteActiveAPIKey()
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("settings.api_delete_key_body"))
        }
        .confirmationDialog(
            L10n.t("settings.pet_remove_title", pendingPetPackRemoval?.displayName ?? ""),
            isPresented: Binding(
                get: { pendingPetPackRemoval != nil },
                set: { if !$0 { pendingPetPackRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.pet_remove_confirm"), role: .destructive) {
                removePendingPetPack()
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                pendingPetPackRemoval = nil
            }
        } message: {
            Text(L10n.t("settings.pet_remove_body"))
        }
    }

    // MARK: - 分组 / 行（线画在行底部 overlay，绝不隔行丢线）

    /// 菜单栏真实 icon 预览条；无监控时 = Mr. Defier 彩色脸
    private var menuBarIconPreviewRow: some View {
        let snapshot = MonitorService.shared.snapshot
        let cpu = menuBarShowCPU && snapshot.cpuIsFresh() ? snapshot.cpu?.totalUsage : nil
        let ram = menuBarShowRAM && snapshot.ramIsFresh() ? snapshot.ram?.usage : nil
        let pack = MenuBarIconRenderer.renderPack(cpu: cpu, ram: ram)
        let image = pack.image
        return HStack(alignment: .center, spacing: 12) {
            Text(L10n.t("settings.menubar_preview"))
                .font(.system(size: 13))
                .foregroundStyle(MDTheme.label)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                // 一律 monochrome template 预览（与真实菜单栏一致）
                Image(nsImage: image)
                    .renderingMode(.template)
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: pack.isTemplate && image.size.width <= 22 ? 22 : nil, height: 22)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(MDTheme.border.opacity(0.7), lineWidth: 0.5)
            )
            .id("mb-\(menuBarShowCPU)-\(menuBarShowRAM)-\(Int((cpu ?? -1) * 100))-\(Int((ram ?? -1) * 100))")
            Button(L10n.t("menupanel.open_panel")) {
                MenuBarController.shared.showPanel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 40)
        .overlay(alignment: .bottom) {
            MDRowSeparator(leading: 14)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.tertiary)
                    .padding(.horizontal, 4)
                    .textCase(.uppercase)
            }
            // 不用 MDGroupedList 包 @ViewBuilder control：会 escaping captures non-escaping
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous)
                    .fill(MDTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous)
                    .stroke(MDTheme.border.opacity(0.5), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous))
        }
    }

    /// Full-row tappable link (chevron on the right).
    private func settingsLinkRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(MDTheme.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// showLine = true：本行底部画分隔线（给「下一行」做分界）
    private func settingsRow<Control: View>(
        _ title: String,
        showLine: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(MDTheme.label)
                    .lineLimit(1)
                    .layoutPriority(0)
                Spacer(minLength: 8)
                control()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 36)
            if showLine {
                MDRowSeparator(leading: 14)
            }
        }
    }

    // MARK: - AI / Pet helpers

    private var activeCloudSummary: String {
        if let p = cloudProfiles.first(where: { $0.id == activeCloudProfileId }) ?? cloudProfiles.first {
            return "\(p.localizedDisplayName) · \(p.model)"
        }
        return cloudModel.isEmpty ? L10n.t("settings.not_configured") : cloudModel
    }

    /// Built-in knight — same row style as imported packs, slightly larger preview.
    private func builtInPetRow(skin: PetSkin, showLine: Bool) -> some View {
        let on = petPackStore.activePackId == nil && petSkinRaw == skin.rawValue
        // Imported packs use 40/34; built-in a bit larger so it’s still the “hero” option.
        let box: CGFloat = 48
        let art: CGFloat = 42
        return Button {
            petSkinRaw = skin.rawValue
            PetSkinStore.current = skin
            petPackStore.selectBuiltIn()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MDTheme.surfaceInset)
                        .frame(width: box, height: box)
                    DefierPetView(
                        mood: .idle,
                        skin: skin,
                        size: art,
                        showsOnlineDot: false,
                        tracksLook: false,
                        preferCustomPack: false
                    ) {}
                    .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(skin.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MDTheme.label)
                        .lineLimit(1)
                    Text(skin.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(MDTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MDTheme.accent)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(on ? MDTheme.surfaceSelected : MDTheme.surface)
            .overlay(alignment: .bottom) {
                if showLine {
                    Rectangle()
                        .fill(MDTheme.separator)
                        .frame(height: 1)
                        .padding(.leading, 12)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func petPackVisualRow(_ pack: PetPack, showLine: Bool) -> some View {
        let on = petPackStore.activePackId == pack.id
        return HStack(spacing: 10) {
            Button {
                petPackStore.selectPack(id: pack.id)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(MDTheme.surfaceInset)
                            .frame(width: 40, height: 40)
                        if let preview = pack.previewImage() {
                            Image(nsImage: preview)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(MDTheme.secondary)
                        }
                    }
                    Text(pack.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MDTheme.label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if on {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MDTheme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                pendingPetPackRemoval = pack
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(MDTheme.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.t("common.delete"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(on ? MDTheme.surfaceSelected : MDTheme.surface)
        .overlay(alignment: .bottom) {
            if showLine {
                Rectangle()
                    .fill(MDTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, 12)
            }
        }
    }

    private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func loadAI() {
        let s = AISettingsStore.load()
        cloudPrivacyAcknowledged = s.cloudPrivacyAcknowledged
        aiEnabled = s.enabled && s.mode != .off
        switch s.mode {
        case .cloud: aiUseCloud = true
        case .localOnly: aiUseCloud = false
        case .localFirst: aiUseCloud = !s.isConfiguredForLocal
        case .off: aiUseCloud = true
        }
        apiKey = s.apiKey
        baseURL = s.baseURL
        cloudModel = s.cloudModel
        localEndpoint = s.localEndpoint
        localModel = s.localModel
        defaultIntensity = s.defaultIntensity
        cloudProfiles = s.cloudProfiles
        activeCloudProfileId = s.activeCloudProfileId
    }

    private func currentAISettings() -> AISettings {
        var profiles = cloudProfiles
        if let id = activeCloudProfileId, let idx = profiles.firstIndex(where: { $0.id == id }) {
            profiles[idx].baseURL = baseURL
            profiles[idx].model = cloudModel
            profiles[idx].apiKey = apiKey
        }
        return AISettings(
            enabled: aiEnabled,
            mode: aiUseCloud ? .cloud : .localOnly,
            apiKey: apiKey,
            baseURL: baseURL,
            cloudModel: cloudModel,
            localEndpoint: localEndpoint,
            localModel: localModel,
            defaultIntensity: defaultIntensity,
            keepRecentTurns: 12,
            historyCharBudget: 12_000,
            cloudProfiles: profiles.isEmpty
                ? [AICloudProfile(name: L10n.t("settings.api_default_name"), baseURL: baseURL, model: cloudModel, apiKey: apiKey)]
                : profiles,
            activeCloudProfileId: activeCloudProfileId,
            cloudPrivacyAcknowledged: cloudPrivacyAcknowledged
        )
    }

    private func selectLocalModel(_ name: String) {
        guard !aiUseCloud, saveAI() else { return }
        localModels.select(name, endpoint: localEndpoint) { model, endpoint in
            // Freeze the chosen endpoint. A download finishing after switching
            // mode, server, or Settings instance must not overwrite that choice.
            var saved = AISettingsStore.load()
            guard saved.mode == .localOnly,
                  (try? OllamaEndpoint.apiURL(saved.localEndpoint, path: "tags"))
                    == (try? OllamaEndpoint.apiURL(endpoint, path: "tags")) else { return }
            saved.localModel = model
            guard AISettingsStore.save(saved) else {
                aiSavedHint = L10n.t("settings.keychain_save_failed")
                return
            }
            localModel = model
            aiSavedHint = L10n.t("settings.saved")
            aiTestResult = ""
            NotificationCenter.default.post(name: .macDefierAISettingsDidChange, object: nil)
        }
    }

    @discardableResult
    private func saveAI() -> Bool {
        // 失焦提交 TextField：避免「界面写了 gemma3、磁盘仍是默认 llama3」
        NSApp.keyWindow?.makeFirstResponder(nil)

        // Endpoint policy：公网 HTTP 禁止落盘为可用配置
        if aiUseCloud {
            let cls = AIEndpointPolicy.classify(baseURL)
            if !cls.isRequestAllowed {
                aiSavedHint = L10n.t("settings.endpoint_public_http_blocked")
                return false
            }
        } else {
            let cls = AIEndpointPolicy.classify(localEndpoint)
            if !cls.isRequestAllowed {
                aiSavedHint = L10n.t("settings.endpoint_public_http_blocked")
                return false
            }
            // M08-1: 「本地」模式禁止公网主机——须改用云端分段 + 隐私确认
            if !AIEndpointPolicy.isAllowedAsLocalModeEndpoint(localEndpoint) {
                aiSavedHint = L10n.t("settings.endpoint_local_public_blocked")
                return false
            }
            // 「本地」指向 LAN/link-local：数据离本机，首次须远程摘要
            if aiEnabled, cls.requiresRemotePrivacyAck, !cloudPrivacyAcknowledged {
                privacyPromptForLANEndpoint = true
                showCloudPrivacyConfirm = true
                return false
            }
            // LAN HTTP 风险先记下，保存成功后仍展示（勿被 settings.saved 覆盖）
            if cls.isLANHTTPRisk {
                lanHTTPRiskPending = true
            }
        }

        // 云端未确认隐私前：不落盘 enabled+cloud（审查 F08-1）
        if aiEnabled, aiUseCloud, hasNewCloudCredential, !cloudPrivacyAcknowledged {
            privacyPromptForLANEndpoint = false
            showCloudPrivacyConfirm = true
            return false
        }
        let saved = AISettingsStore.save(currentAISettings())
        if !saved {
            aiSavedHint = L10n.t("settings.keychain_save_failed")
            return false
        }
        // 成功：保存文案 + 若有 LAN HTTP 风险则追加（不得只显示 saved）
        if lanHTTPRiskPending || (!aiUseCloud && AIEndpointPolicy.classify(localEndpoint).isLANHTTPRisk) {
            aiSavedHint = L10n.t("settings.saved") + " · " + L10n.t("settings.endpoint_lan_http_risk")
            lanHTTPRiskPending = false
        } else {
            aiSavedHint = L10n.t("settings.saved")
        }
        aiTestResult = ""
        // 成功才从磁盘回读；失败保留界面输入（含 draft Key）
        let s = AISettingsStore.load()
        cloudProfiles = s.cloudProfiles
        activeCloudProfileId = s.activeCloudProfileId
        apiKey = s.apiKey
        baseURL = s.baseURL
        cloudModel = s.cloudModel
        localEndpoint = s.localEndpoint
        localModel = s.localModel
        cloudPrivacyAcknowledged = s.cloudPrivacyAcknowledged
        NotificationCenter.default.post(name: .macDefierAISettingsDidChange, object: nil)
        return true
    }

    private func deleteActiveAPIKey() {
        guard let id = activeCloudProfileId else { return }
        guard AISettingsStore.deleteAPIKey(profileID: id) else {
            aiSavedHint = L10n.t("settings.api_delete_key_failed")
            return
        }
        apiKey = ""
        if let idx = cloudProfiles.firstIndex(where: { $0.id == id }) {
            cloudProfiles[idx].apiKey = ""
        }
        guard AISettingsStore.save(currentAISettings()) else {
            aiSavedHint = L10n.t("settings.keychain_save_failed")
            return
        }
        loadAI()
        aiSavedHint = L10n.t("settings.api_delete_key_done")
        NotificationCenter.default.post(name: .macDefierAISettingsDidChange, object: nil)
    }

    private func testAI() async {
        if aiEnabled, aiUseCloud, hasNewCloudCredential, !cloudPrivacyAcknowledged {
            privacyPromptForLANEndpoint = false
            showCloudPrivacyConfirm = true
            return
        }
        guard saveAI() else { return }
        aiTesting = true
        aiTestResult = L10n.t("settings.testing")
        aiTestResult = await AIClient.testConnection(settings: AISettingsStore.load())
        aiTesting = false
    }

    private func removePendingPetPack() {
        guard let pack = pendingPetPackRemoval else { return }
        pendingPetPackRemoval = nil
        do {
            try petPackStore.removePack(id: pack.id)
            petPackHint = L10n.t("settings.pet_removed", pack.displayName)
        } catch {
            petPackHint = L10n.t("settings.pet_remove_failed", error.localizedDescription)
        }
    }

    private func importPetPack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = L10n.t("settings.import_pet_panel")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        petPackHint = L10n.t("settings.pet_importing")
        isPetImporting = true
        petImportTask = Task {
            defer {
                isPetImporting = false
                petImportTask = nil
            }
            do {
                let pack = try await petPackStore.importZip(from: url)
                petPackHint = L10n.t("settings.pet_imported", pack.displayName)
            } catch is CancellationError {
                petPackHint = L10n.t("settings.pet_import_cancelled")
            } catch let e as PetPackError {
                petPackHint = L10n.t("settings.pet_import_fail", L10n.t(e.localizationKey))
            } catch {
                petPackHint = L10n.t("settings.pet_import_fail", error.localizedDescription)
            }
        }
    }

    private var hasNewCloudCredential: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || cloudProfiles.contains { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: - 云端配置弹窗（独立 draft，确认前不写 UserDefaults/Keychain）

private enum CloudProfilesSheetResult {
    case cancelled
    case saved(profiles: [AICloudProfile], activeId: String?, acknowledged: Bool)
}

private struct CloudProfilesSheet: View {
    let initialProfiles: [AICloudProfile]
    let initialActiveId: String?
    let privacyAlreadyAcknowledged: Bool
    var onFinish: (CloudProfilesSheetResult) -> Void

    @State private var draftProfiles: [AICloudProfile] = []
    @State private var draftActiveId: String?
    @State private var editing: AICloudProfile?
    @State private var isNew = false
    @State private var showPrivacy = false
    @State private var pendingAckSave = false
    @State private var endpointHint = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("settings.api_sheet_title"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L10n.t("common.cancel")) {
                    onFinish(.cancelled)
                }
                Button(L10n.t("common.done")) { attemptCommit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Rectangle().fill(MDTheme.separator).frame(height: 1)

            if editing != nil {
                editForm
            } else {
                listPane
            }
            if !endpointHint.isEmpty {
                Text(endpointHint)
                    .font(.system(size: 11))
                    .foregroundStyle(MDTheme.warning)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 440, height: 420)
        .background(MDTheme.content)
        .onAppear {
            draftProfiles = initialProfiles
            draftActiveId = initialActiveId
        }
        .confirmationDialog(
            L10n.t("settings.cloud_confirm_title"),
            isPresented: $showPrivacy,
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.cloud_confirm_ok")) {
                pendingAckSave = true
                commit(acknowledged: true)
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                // 取消确认：保留 draft，不落盘
                pendingAckSave = false
            }
        } message: {
            Text(L10n.t("settings.cloud_confirm_body"))
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            if draftProfiles.isEmpty {
                Text(L10n.t("settings.api_empty"))
                    .foregroundStyle(MDTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(draftProfiles.enumerated()), id: \.element.id) { idx, p in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.localizedDisplayName)
                                        .font(.system(size: 13, weight: .medium))
                                    Text("\(p.model) · \(p.baseURL)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(MDTheme.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if p.id == draftActiveId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(MDTheme.accent)
                                }
                                Button(L10n.t("settings.api_edit")) {
                                    isNew = false
                                    editing = p
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture { draftActiveId = p.id }
                            .background(p.id == draftActiveId ? MDTheme.surfaceSelected : MDTheme.surface)
                            .overlay(alignment: .bottom) {
                                if idx < draftProfiles.count - 1 {
                                    Rectangle()
                                        .fill(MDTheme.separator)
                                        .frame(height: 1)
                                        .padding(.leading, 14)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Button {
                    isNew = true
                    editing = AICloudProfile(name: L10n.t("settings.api_config_n", draftProfiles.count + 1))
                } label: {
                    Label(L10n.t("settings.api_add"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
                if let id = draftActiveId, draftProfiles.count > 1 {
                    Button(L10n.t("settings.api_delete"), role: .destructive) {
                        draftProfiles.removeAll { $0.id == id }
                        draftActiveId = draftProfiles.first?.id
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
        }
    }

    private var editForm: some View {
        let binding = Binding(
            get: { editing ?? AICloudProfile(name: "") },
            set: { editing = $0 }
        )
        return Form {
            TextField(L10n.t("settings.api_name"), text: binding.name)
            TextField(L10n.t("settings.api_base_url"), text: binding.baseURL)
            SecureField(L10n.t("settings.api_key"), text: binding.apiKey)
            TextField(L10n.t("settings.model"), text: binding.model)
            endpointPolicyHint(for: binding.wrappedValue.baseURL)
            HStack {
                Button(L10n.t("common.cancel")) { editing = nil }
                Spacer()
                Button(L10n.t("settings.api_store")) {
                    var p = binding.wrappedValue
                    if p.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        p.name = L10n.t("settings.api_unnamed")
                    }
                    let cls = AIEndpointPolicy.classify(p.baseURL)
                    if !cls.isRequestAllowed {
                        endpointHint = L10n.t("settings.endpoint_public_http_blocked")
                        return
                    }
                    if cls.isLANHTTPRisk {
                        endpointHint = L10n.t("settings.endpoint_lan_http_risk")
                    } else {
                        endpointHint = ""
                    }
                    if isNew {
                        draftProfiles.append(p)
                        draftActiveId = p.id
                    } else if let idx = draftProfiles.firstIndex(where: { $0.id == p.id }) {
                        draftProfiles[idx] = p
                    }
                    editing = nil
                    isNew = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    @ViewBuilder
    private func endpointPolicyHint(for base: String) -> some View {
        let cls = AIEndpointPolicy.classify(base)
        if cls.kind == .invalid {
            Text(L10n.t("settings.endpoint_public_http_blocked"))
                .font(.system(size: 11))
                .foregroundStyle(MDTheme.warning)
        } else if cls.isLANHTTPRisk {
            Text(L10n.t("settings.endpoint_lan_http_risk"))
                .font(.system(size: 11))
                .foregroundStyle(MDTheme.warning)
        } else if cls.requiresRemotePrivacyAck {
            Text(L10n.t("settings.endpoint_leaves_device"))
                .font(.system(size: 11))
                .foregroundStyle(MDTheme.secondary)
        }
    }

    private var needsFirstRemoteAck: Bool {
        guard !privacyAlreadyAcknowledged else { return false }
        // 首次新增：任一 draft 含 Key 且 endpoint 非 loopback
        return draftProfiles.contains { p in
            let hasKey = !p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasKey else { return false }
            return AIEndpointPolicy.classify(p.baseURL).requiresRemotePrivacyAck
        }
    }

    private func attemptCommit() {
        // 校验全部 draft URL
        for p in draftProfiles {
            let cls = AIEndpointPolicy.classify(p.baseURL)
            if !cls.isRequestAllowed {
                endpointHint = L10n.t("settings.endpoint_public_http_blocked")
                return
            }
        }
        if needsFirstRemoteAck {
            showPrivacy = true
            return
        }
        commit(acknowledged: privacyAlreadyAcknowledged)
    }

    private func commit(acknowledged: Bool) {
        onFinish(.saved(
            profiles: draftProfiles,
            activeId: draftActiveId,
            acknowledged: acknowledged
        ))
    }
}
