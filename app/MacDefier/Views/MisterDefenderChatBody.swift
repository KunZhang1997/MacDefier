import SwiftUI
import AppKit
import MonitorKit

/// Mr. Defier chat body — native message list (reliable scroll) + MacDefier input.
/// Network / Key / intensity / stop / persistence: still `AIChatViewModel`.
/// Native list UI avoids the macOS panel scrolling bugs from the retired package adapter.
struct MisterDefenderChatBody: View {
    @ObservedObject var vm: AIChatViewModel
    var skin: PetSkin = PetSkinStore.current
    @EnvironmentObject private var monitor: MonitorService
    @ObservedObject private var nav = AppNavigator.shared

    @State private var draft = ""
    @State private var scrollToken = 0

    /// When false, intensity + clear live in panel header (overlay) — avoid double chrome.
    var showsToolbar: Bool = true

    private var usesLocalSetup: Bool {
        vm.settings.mode == .localOnly || vm.settings.mode == .localFirst
    }

    private var setupTitle: String {
        L10n.t(usesLocalSetup ? "chat.setup_local" : "chat.setup_api")
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsToolbar {
                chatToolbar
                Divider()
            }
            messageArea
            inputBar
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.9),
                    Color(nsColor: .controlBackgroundColor).opacity(0.5)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            vm.reloadSettings()
            draft = vm.input
            // 面板一打开就滚到最新
            bumpScroll(delay: 0.05)
            bumpScroll(delay: 0.25)
        }
        .onChange(of: vm.messages.count) { _, _ in
            bumpScroll(delay: 0.02)
            bumpScroll(delay: 0.15)
        }
        .onChange(of: vm.messages.last?.content) { _, _ in
            // streaming / last message grows
            bumpScroll(delay: 0.02)
        }
        .onChange(of: vm.isSending) { _, sending in
            if sending {
                bumpScroll(delay: 0.02)
                bumpScroll(delay: 0.12)
            }
        }
        .onChange(of: draft) { _, new in
            vm.input = new
        }
        .onChange(of: skin) { _, _ in
            // 头像随皮肤；强制重绘
            scrollToken &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDefierConversationDidClear)) { _ in
            vm.clear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDefierAISettingsDidChange)) { _ in
            vm.reloadSettings()
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private var messageArea: some View {
        // 发送中也进列表区（底部 loading 气泡），不要卡在 emptyState 看不见进度
        if vm.messages.isEmpty, !vm.isSending {
            emptyState
        } else {
            GeometryReader { geo in
                let bubbleMax = max(120, geo.size.width * 0.78)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            // 顶垫：少量消息时也贴底视觉
                            Color.clear.frame(height: 4)

                            if let hint = vm.restoredHint, !hint.isEmpty {
                                Text(hint)
                                    .font(.system(size: 11))
                                    .foregroundStyle(MDTheme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 4)
                            }

                            ForEach(vm.messages) { msg in
                                messageRow(msg, bubbleMax: bubbleMax)
                                    .id(msg.id)
                            }

                            if vm.isSending {
                                loadingBubble(bubbleMax: bubbleMax)
                                    .id("chat-loading")
                            }

                            // 底锚点：始终可 scrollTo
                            Color.clear
                                .frame(height: 1)
                                .id("chat-bottom")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minWidth: geo.size.width, maxWidth: geo.size.width, alignment: .topLeading)
                    }
                    .onChange(of: scrollToken) { _, _ in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 等待回复时的行内加载标识（转圈 + 状态文案）
    private func loadingBubble(bubbleMax: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: DefierAvatar.image(size: 32, skin: skin))
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(MDTheme.subtleBorder.opacity(0.75), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Mr. Defier")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MDTheme.secondary)

                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loadingStatusText)
                        .font(.system(size: 13))
                        .foregroundStyle(MDTheme.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: min(bubbleMax, 280), alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(MDTheme.accent.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            }

            Spacer(minLength: 24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(loadingStatusText)
    }

    private var loadingStatusText: String {
        let s = vm.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return AppLanguage.current.isEnglish ? "Thinking…" : "正在想…"
    }

    private func messageRow(_ msg: AIMessage, bubbleMax: CGFloat) -> some View {
        let isUser = msg.role == .user
        return HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 36) }

            if !isUser {
                Image(nsImage: DefierAvatar.image(size: 32, skin: skin))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(MDTheme.subtleBorder.opacity(0.75), lineWidth: 0.5)
                    )
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser {
                    Text("Mr. Defier")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MDTheme.secondary)
                }

                if !msg.content.isEmpty {
                    Text(msg.content)
                        .font(.system(size: 13.5))
                        .foregroundStyle(isUser ? Color.white : MDTheme.label)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: bubbleMax, alignment: isUser ? .trailing : .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isUser ? Color(hex: 0x0A84FF) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isUser ? Color.clear : MDTheme.subtleBorder.opacity(0.75), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(isUser ? 0.12 : 0.06), radius: isUser ? 4 : 2, y: 1)
                        .contextMenu {
                            Button {
                                copy(msg.content)
                            } label: {
                                Label(L10n.t("chat.copy"), systemImage: "doc.on.doc")
                            }
                            if let think = msg.thinking, !think.isEmpty {
                                Button {
                                    copy(think)
                                } label: {
                                    Label(L10n.t("chat.copy_think"), systemImage: "brain")
                                }
                            }
                        }
                }

                // Action cards: real work, not pure prose
                if !isUser, !msg.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(msg.actions) { action in
                            actionCard(action, maxWidth: bubbleMax)
                        }
                    }
                    .frame(maxWidth: bubbleMax, alignment: .leading)
                }

                if let think = msg.thinking, !think.isEmpty, !isUser {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { vm.expandedThinkingIDs.contains(msg.id) },
                            set: { on in
                                if on { vm.expandedThinkingIDs.insert(msg.id) }
                                else { vm.expandedThinkingIDs.remove(msg.id) }
                            }
                        )
                    ) {
                        Text(think)
                            .font(.system(size: 11))
                            .foregroundStyle(MDTheme.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Text(L10n.t("chat.thinking"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MDTheme.tertiary)
                    }
                    .frame(maxWidth: bubbleMax, alignment: .leading)
                }
            }

            if !isUser { Spacer(minLength: 24) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 8)
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: DefierAvatar.image(size: 40, skin: skin))
                    .resizable()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mr. Defier")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MDTheme.secondary)
                    Text(emptyBodyText)
                        .font(.system(size: 13.5))
                        .foregroundStyle(MDTheme.label)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(MDTheme.subtleBorder.opacity(0.75), lineWidth: 0.5)
                        )
                        .textSelection(.enabled)

                    // AI 关 / 未填 Key：空态直接给「去设置」入口，不用先发一句才看到
                    if vm.needsAISetupGuide {
                        Button {
                            nav.handle(DefierAction(
                                kind: .openSettings,
                                title: setupTitle,
                                detail: L10n.t("chat.setup_api_detail")
                            ))
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: usesLocalSetup ? "arrow.down.circle.fill" : "key.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(setupTitle)
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(MDTheme.accent))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("chat.setup_api_detail"))
                        .padding(.top, 2)
                    }

                    // 说法示例：一点就当用户输入发出（规则意图不依赖 AI）
                    FlowExampleChips(phrases: ChatIntentRouter.examplePhrases) { text in
                        draft = text
                        send()
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id("empty-\(skin.rawValue)-\(vm.needsAISetupGuide)")
    }

    private var emptyBodyText: String {
        if vm.isAIDisabled {
            return L10n.t("chat.empty_ai_off")
        }
        if vm.needsAPISetup {
            return L10n.t("chat.empty_need_api")
        }
        return L10n.t("chat.empty_body")
    }

    // MARK: - Toolbar（强度 + 清空；加载只在消息列表气泡里出现一次）

    private var chatToolbar: some View {
        HStack(spacing: 8) {
            intensityMenu
            if !vm.messages.isEmpty {
                Button {
                    vm.clear()
                } label: {
                    Text(AppLanguage.current.isEnglish ? "Clear" : "清空")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(MDTheme.secondary)
                .help(AppLanguage.current.isEnglish ? "Clear chat history" : "删除本机保存的聊天记录")
            }
            Spacer(minLength: 0)
            if vm.needsAISetupGuide {
                Button {
                    nav.handle(DefierAction(
                        kind: .openSettings,
                        title: L10n.t("chat.setup_api"),
                        detail: L10n.t("chat.setup_api_detail")
                    ))
                } label: {
                    Text(vm.status.isEmpty ? L10n.t("chat.setup_api") : vm.status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MDTheme.accent)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .help(L10n.t("chat.setup_api_detail"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var intensityMenu: some View {
        Menu {
            Section(AppLanguage.current.isEnglish ? "Intensity" : "强度") {
                ForEach(AIIntensity.allCases) { level in
                    Button {
                        vm.intensity = level
                        vm.noteSettingsChanged()
                    } label: {
                        HStack {
                            Text("\(level.title) · \(level.subtitle)")
                            if vm.intensity == level { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section(AppLanguage.current.isEnglish ? "Model (Settings)" : "模型（设置里改）") {
                Text(AIClient.resolveEndpoint(vm.settings)?.model
                     ?? (AppLanguage.current.isEnglish ? "Not configured" : "未配置"))
            }
        } label: {
            HStack(spacing: 4) {
                Text(intensityShortLabel)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(MDTheme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(MDTheme.surfaceInset))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(AppLanguage.current.isEnglish ? "Reply intensity" : "回复强度")
    }

    private var intensityShortLabel: String {
        switch vm.intensity {
        case .light: return AppLanguage.current.isEnglish ? "Light" : "轻"
        case .standard: return AppLanguage.current.isEnglish ? "Std" : "标准"
        case .deep: return AppLanguage.current.isEnglish ? "Deep" : "深"
        }
    }

    // MARK: - Input（单行长输入 + 发送，不再堆模型/状态）

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    AppLanguage.current.isEnglish ? "Message Mr. Defier…" : "问 Mr. Defier…",
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(MDTheme.subtleBorder, lineWidth: 0.5)
                )
                .onSubmit { send() }

                Button {
                    if vm.isSending { vm.stop() } else { send() }
                } label: {
                    Image(systemName: vm.isSending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(vm.isSending ? Color.orange : MDTheme.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!vm.isSending && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(vm.isSending
                      ? (AppLanguage.current.isEnglish ? "Stop" : "停止")
                      : (AppLanguage.current.isEnglish ? "Send" : "发送"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        vm.input = text
        draft = ""
        vm.send(monitor: monitor)
        bumpScroll(delay: 0.05)
    }

    private func actionCard(_ action: DefierAction, maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(for: action.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MDTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.buttonLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(MDTheme.label)
                        .lineLimit(2)
                    if !action.detail.isEmpty {
                        Text(action.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(MDTheme.secondary)
                            .lineLimit(3)
                    }
                    if let m = action.metric, !m.isEmpty {
                        Text(m)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(MDTheme.tertiary)
                    }
                }
                Spacer(minLength: 4)
                Button(cta(for: action.kind)) {
                    nav.handle(action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MDTheme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    private func icon(for kind: DefierAction.Kind) -> String {
        switch kind {
        case .cleanup: return "trash"
        case .uninstall: return "shippingbox"
        case .openSoftware: return "square.grid.2x2"
        // fallthrough handled below if more cases exist
        case .openMonitor: return "gauge.with.dots.needle.67percent"
        case .openDiagnostic: return "stethoscope"
        case .quitProcess: return "xmark.circle"
        case .openSettings: return "gearshape"
        case .none: return "arrow.right.circle"
        }
    }

    private func cta(for kind: DefierAction.Kind) -> String {
        // Navigation-only wording — never sound like instant delete/uninstall.
        switch kind {
        case .cleanup, .openSoftware, .openMonitor, .openDiagnostic, .openSettings:
            return L10n.t("chat.act.open")
        case .uninstall: return L10n.t("chat.act.preview")
        case .quitProcess: return L10n.t("chat.act.quit")
        case .none: return L10n.t("chat.act.go")
        }
    }

    private func bumpScroll(delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            scrollToken &+= 1
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - 空态说法芯片（简单换行，不引第三方）

private struct FlowExampleChips: View {
    let phrases: [(label: String, text: String)]
    var onPick: (String) -> Void

    var body: some View {
        // 固定两行布局，避免复杂测量
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(phrases.prefix(2).enumerated()), id: \.offset) { _, p in
                    chip(p)
                }
            }
            HStack(spacing: 6) {
                ForEach(Array(phrases.dropFirst(2).enumerated()), id: \.offset) { _, p in
                    chip(p)
                }
            }
        }
    }

    private func chip(_ p: (label: String, text: String)) -> some View {
        Button {
            onPick(p.text)
        } label: {
            Text(p.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MDTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(MDTheme.accent.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(p.text)
    }
}
