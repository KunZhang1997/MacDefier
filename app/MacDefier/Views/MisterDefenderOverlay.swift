import AppKit
import SwiftUI
import MonitorKit
import UniformTypeIdentifiers

/// Mr. Defier — window-internal pet + chat panel.
/// Pet uses AppKit drag so it won't move the window.
/// Open chat always shows a fully-visible adaptive panel (not a clipped “mini” slice).
struct MisterDefenderOverlay: View {
    @EnvironmentObject private var monitor: MonitorService
    @ObservedObject private var scan = DiagnosticScanService.shared
    @ObservedObject private var packStore = PetPackStore.shared
    @StateObject private var vm = AIChatViewModel()
    @StateObject private var pet = PetCoordinator()
    @Binding var isOpen: Bool
    var dockInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage(PetSkinStore.appStorageKey) private var skinRaw: String = PetSkinStore.defaultSkin.rawValue
    @AppStorage("ai.enabled") private var aiEnabled: Bool = true
    @AppStorage("ai.mode") private var aiModeRaw: String = AISettings.Mode.cloud.rawValue
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.chinese.rawValue

    @AppStorage("pet.drag.x") private var savedDragX: Double = 0
    @AppStorage("pet.drag.y") private var savedDragY: Double = 0

    @State private var showPill = false
    @State private var liveDrag: CGSize = .zero
    /// Velocity + active flag for cape cloth physics on the pet.
    @State private var petDragMotion: PetDragMotion = .init()
    @State private var windowSize: CGSize = CGSize(width: WindowChrome.defaultWidth, height: WindowChrome.defaultHeight)

    private let margin: CGFloat = 12
    private let petClosed: CGFloat = 72
    private let petOpen: CGFloat = 72

    private var skin: PetSkin {
        PetSkin(rawValue: skinRaw) ?? PetSkinStore.defaultSkin
    }

    private var aiIsOff: Bool {
        !aiEnabled || aiModeRaw == AISettings.Mode.off.rawValue
    }

    private var panelIntensityLabel: String {
        switch vm.intensity {
        case .light: return AppLanguage.current.isEnglish ? "Light" : "轻"
        case .standard: return AppLanguage.current.isEnglish ? "Std" : "标准"
        case .deep: return AppLanguage.current.isEnglish ? "Deep" : "深"
        }
    }

    private var panelSubtitle: String {
        if vm.isAIDisabled {
            return L10n.t("chat.ai_off")
        }
        if vm.needsAPISetup {
            return AppLanguage.current.isEnglish ? "AI not configured" : "AI 尚未配置"
        }
        if let name = packStore.activePack?.displayName {
            return (AppLanguage.current.isEnglish ? "Assistant · pet: " : "助手 · 窗宠：") + name
        }
        return petMood.whenHint
    }

    /// Mood from coordinator (diagnosis / cleanup / monitor / AI / chat).
    private var petMood: PetMood { pet.mood }

    /// Visual + hit size of the closed/open pet only (must match laid-out pet frame).
    private var petLayoutSize: CGSize {
        let s = isOpen ? petOpen : petClosed
        // Match DefierPetView stack proportions
        return CGSize(width: s * 1.12, height: s * 1.48)
    }

    private var panelSize: CGSize {
        CGSize(width: min(420, windowSize.width - margin * 2),
               height: min(480, windowSize.height - margin * 2))
    }

    /// Bubble may wrap past this; short lines hug content (true adaptive).
    private var banterMaxWidth: CGFloat {
        // Responsive to window, not a hard tiny box
        max(160, min(330, windowSize.width * 0.42))
    }

    var body: some View {
        GeometryReader { geo in
            let clamped = clampOffset(
                CGSize(width: savedDragX + liveDrag.width, height: savedDragY + liveDrag.height),
                in: geo.size, stack: petLayoutSize, margin: margin
            )
            let petRect = PetOverlayGeometry.petFrame(offset: clamped, window: geo.size,
                                                       size: petLayoutSize, margin: margin)
            let popupRect = PetOverlayGeometry.popupFrame(near: petRect, window: geo.size,
                                                           preferred: panelSize, margin: margin)
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if isOpen {
                    panel(size: popupRect.size, window: geo.size)
                        .position(x: popupRect.midX, y: popupRect.midY)
                        .transition(.opacity)
                } else if showPill {
                    let pillRect = PetOverlayGeometry.popupFrame(
                        near: petRect, window: geo.size,
                        preferred: CGSize(width: 180, height: 44), margin: margin)
                    PetDragContainer(
                        onDragChanged: { applyLiveDrag($0) },
                        onDragEnded: { endDrag($0, window: geo.size) },
                        onClick: { openChat(window: geo.size) },
                        onDoubleClick: { resetPosition() }
                    ) { pillLabel }
                    .frame(width: pillRect.width, height: pillRect.height)
                    .position(x: pillRect.midX, y: pillRect.midY)
                } else if let line = pet.banterLine {
                    let bubbleRect = PetOverlayGeometry.popupFrame(
                        near: petRect, window: geo.size,
                        preferred: CGSize(width: min(banterMaxWidth, 330), height: 88), margin: margin)
                    banterBubble(line)
                        .frame(width: bubbleRect.width, height: bubbleRect.height)
                        .position(x: bubbleRect.midX, y: bubbleRect.midY)
                        .allowsHitTesting(false)
                }
                petWithBanter(window: geo.size)
                    .position(x: petRect.midX, y: petRect.midY)
                    .help(L10n.t("pet.help_drag"))
                    .contextMenu {
                        Button(AppLanguage.current.isEnglish ? "Open chat" : "打开对话") {
                            openChat(window: geo.size)
                        }
                        Button(AppLanguage.current.isEnglish ? "Reset position" : "位置复位") {
                            resetPosition()
                        }
                        Button(L10n.t("pet.open_settings")) {
                            AppNavigator.shared.route = .settings
                            AppNavigator.shared.misterOpen = false
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
                .onAppear {
                    windowSize = geo.size
                    // Preserve the user's position; changing routes must not move the pet.
                    if savedDragX == 0 && savedDragY == 0 { savedDragY = -dockInset }
                    reclamp(window: geo.size)
                    vm.reloadSettings()
                    pet.start(monitor: monitor)
                    pet.setChatOpen(isOpen)
                    pet.setAIOff(aiIsOff)
                    pet.setAISending(vm.isSending)
                    MonitorAIAssist.shared.start(monitor: monitor)
                }
                .onDisappear {
                    pet.stop()
                }
                .onReceive(NotificationCenter.default.publisher(for: .monitorIPExitChanged)) { note in
                    if let line = note.userInfo?["line"] as? String {
                        pet.announce(line: line)
                    }
                    // 对话里落一句（不刷屏：同文案不重复）
                    if let line = note.userInfo?["line"] as? String {
                        injectIPTipIntoChat(line)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { note in
                    guard let window = note.object as? NSWindow, window == NSApp.mainWindow else { return }
                    pet.stop()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                    guard let window = note.object as? NSWindow, window == NSApp.mainWindow else { return }
                    if window.occlusionState.contains(.visible) && !window.isMiniaturized {
                        pet.start(monitor: monitor)
                    } else {
                        pet.stop()
                    }
                }
                .onChange(of: geo.size) { _, newSize in
                    windowSize = newSize
                    reclamp(window: newSize)
                }
                .onChange(of: isOpen) { _, open in
                    pet.setChatOpen(open)
                    if open {
                        ensurePanelFullyVisible(window: geo.size)
                    } else {
                        reclamp(window: geo.size)
                    }
                }
                .onChange(of: aiEnabled) { _, _ in
                    pet.setAIOff(aiIsOff)
                    vm.reloadSettings()
                }
                .onChange(of: aiModeRaw) { _, _ in
                    pet.setAIOff(aiIsOff)
                    vm.reloadSettings()
                }
                .onChange(of: appLanguageRaw) { _, _ in
                    // Generated findings must switch language even away from Home.
                    // Historical chat messages remain untouched.
                    pet.clearBanter()
                    scan.relocalizeForCurrentLanguage(monitor: monitor)
                }
                .onChange(of: vm.isSending) { _, sending in pet.setAISending(sending) }
                .onChange(of: packStore.activePackId) { _, _ in
                    reclamp(window: geo.size)
                }
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isOpen)
        .animation(.easeInOut(duration: 0.15), value: showPill)
        .animation(.easeInOut(duration: 0.2), value: pet.mood)
        .animation(.easeInOut(duration: 0.2), value: skinRaw)
        .animation(.easeInOut(duration: 0.2), value: packStore.activePackId)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: pet.banterLine)
    }

    // MARK: - Actions

    private func toggleChat(window: CGSize) {
        if isOpen {
            // 点宠物关闭完整面板（不是收成 pill）
            isOpen = false
            showPill = false
        } else {
            openChat(window: window)
        }
    }

    private func openChat(window: CGSize) {
        showPill = false
        isOpen = true
        vm.reloadSettings()
        ensurePanelFullyVisible(window: window)
    }

    private func minimizeToPill() {
        isOpen = false
        showPill = true
    }

    private func closeAll() {
        isOpen = false
        showPill = false
    }

    private func applyLiveDrag(_ motion: PetDragMotion) {
        // Position only — avoid Transaction/animation so drag stays light
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            liveDrag = motion.translation
            petDragMotion = PetDragMotion(
                translation: motion.translation,
                velocity: motion.velocity,
                isActive: true
            )
        }
    }

    private func endDrag(_ motion: PetDragMotion, window: CGSize) {
        windowSize = window
        let next = clampOffset(
            CGSize(width: savedDragX + motion.translation.width,
                   height: savedDragY + motion.translation.height),
            in: window, stack: petLayoutSize, margin: margin)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            savedDragX = next.width
            savedDragY = next.height
            liveDrag = .zero
            petDragMotion = PetDragMotion(translation: .zero, velocity: motion.velocity, isActive: false)
        }
    }

    private func reclamp(window: CGSize) {
        windowSize = window
        let next = clampOffset(CGSize(width: savedDragX, height: savedDragY),
                               in: window, stack: petLayoutSize, margin: margin)
        savedDragX = next.width
        savedDragY = next.height
        liveDrag = .zero
    }

    // The popup is clamped separately in body. Opening it must not teleport the pet.
    private func ensurePanelFullyVisible(window: CGSize) {
        windowSize = window
        reclamp(window: window)
    }

    private func moveWithKeyboard(_ delta: CGSize) {
        endDrag(PetDragMotion(translation: delta), window: windowSize)
    }

    private func resetPosition() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            savedDragX = 0
            savedDragY = -dockInset
            liveDrag = .zero
            petDragMotion = .init()
        }
    }

    /// 锚点右下：X ≤ 0 向左，Y ≤ 0 向上。
    private func clampOffset(_ offset: CGSize, in window: CGSize, stack: CGSize, margin: CGFloat) -> CGSize {
        PetOverlayGeometry.clamp(offset, window: window, size: stack, margin: margin)
    }

    /// Pet hit/layout box is fixed; banter is drawn above and does not participate in size.
    @ViewBuilder
    private func petWithBanter(window: CGSize) -> some View {
        let petBox = petLayoutSize
        let petS = isOpen ? petOpen : petClosed

        ZStack(alignment: .bottom) {
            PetDragContainer(
                onDragChanged: { applyLiveDrag($0) },
                onDragEnded: { endDrag($0, window: window) },
                onClick: { toggleChat(window: window) },
                onDoubleClick: { resetPosition() },
                accessibilityLabel: "Mr. Defier",
                onKeyboardMove: { moveWithKeyboard($0) }
            ) {
                DefierPetView(
                    mood: pet.mood,
                    skin: skin,
                    size: petS,
                    showsOnlineDot: false,
                    tracksLook: packStore.activePackId == nil && !aiIsOff,
                    preferCustomPack: true,
                    dimmed: aiIsOff,
                    dragMotion: petDragMotion
                ) {}
                .allowsHitTesting(false)
            }
            .frame(width: petBox.width, height: petBox.height)
        }
        // HARD lock: layout == pet only (bubble never expands this)
        .frame(width: petBox.width, height: petBox.height)

    }

    /// True adaptive bubble via text measurement:
    /// short → width = text; long → wrap at max, height grows; never a fixed empty bar.
    private func banterBubble(_ text: String) -> some View {
        let padX: CGFloat = 14
        let padY: CGFloat = 9
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let singleW = (text as NSString).size(withAttributes: [.font: font]).width
        let maxContentW = max(80, banterMaxWidth - padX * 2)
        let fitsOneLine = singleW <= maxContentW
        let contentW = fitsOneLine ? singleW : maxContentW

        return Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MDTheme.label)
            .multilineTextAlignment(.center)
            .lineLimit(fitsOneLine ? 1 : 6)
            .frame(width: contentW, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, padX)
            .padding(.vertical, padY)
            .background(reduceTransparency ? AnyShapeStyle(MDTheme.surface) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(MDTheme.subtleBorder, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .fixedSize()
            .accessibilityLabel("Mr. Defier: \(text)")
    }

    // MARK: - UI pieces

    private var pillLabel: some View {
        HStack(spacing: 8) {
            // 胶囊条 = 窗宠入口，可用自定义包形象
            DefierPetView(
                mood: petMood,
                skin: skin,
                size: 28,
                showsOnlineDot: false,
                tracksLook: false,
                preferCustomPack: true,
                dimmed: aiIsOff
            ) {}
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                Text("Mr. Defier")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MDTheme.label)
                if let name = packStore.activePack?.displayName {
                    Text(L10n.t("pet.window_label", name))
                        .font(.system(size: 9))
                        .foregroundStyle(MDTheme.secondary)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func panel(size: CGSize, window: CGSize) -> some View {
        VStack(spacing: 0) {
            // Header: 对话品牌固定 Mr. Defier（内置头像），与窗宠形象解耦
            ZStack(alignment: .trailing) {
                PetDragContainer(
                    onDragChanged: { applyLiveDrag($0) },
                    onDragEnded: { endDrag($0, window: window) },
                    onClick: {},
                    onDoubleClick: { resetPosition() }
                ) {
                    HStack(spacing: 10) {
                        // 强制内置皮肤头像，不用自定义包
                        DefierPetView(
                            mood: vm.isSending ? .talk : .happy,
                            skin: skin,
                            size: 28,
                            showsOnlineDot: false,
                            tracksLook: false,
                            preferCustomPack: false,
                            dimmed: aiIsOff
                        ) {}
                        .allowsHitTesting(false)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mr. Defier")
                                .font(.system(size: 14, weight: .semibold))
                        }

                        Spacer(minLength: 132)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: 0x007AFF).opacity(0.08), Color(hex: 0xAF52DE).opacity(0.08)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }

                HStack(spacing: 6) {
                    // 右上：强度切换 + 清空（不与底部重复）
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
                        Section(AppLanguage.current.isEnglish ? "Model (edit in Settings)" : "模型（设置里改）") {
                            Text(AIClient.resolveEndpoint(vm.settings)?.model
                                 ?? (AppLanguage.current.isEnglish ? "Not configured" : "未配置"))
                        }
                        Divider()
                        Button(AppLanguage.current.isEnglish ? "Reset position" : "位置复位") {
                            resetPosition()
                        }
                        if !vm.messages.isEmpty {
                            Button(AppLanguage.current.isEnglish ? "Clear chat" : "清空对话") { vm.clear() }
                        }
                    } label: {
                        Text(panelIntensityLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MDTheme.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(MDTheme.surfaceInset))
                    }
                    .menuStyle(.borderlessButton)
                    .help(AppLanguage.current.isEnglish ? "Intensity" : "回复强度")

                    Button { minimizeToPill() } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MDTheme.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(AppLanguage.current.isEnglish ? "Minimize chat" : "收起对话")
                    .accessibilityLabel(AppLanguage.current.isEnglish ? "Minimize chat" : "收起对话")

                    Button { closeAll() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MDTheme.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("common.close"))
                    .accessibilityLabel(L10n.t("common.close"))
                }
                .padding(.trailing, 8)
            }
            .frame(height: 56)

            Divider()
            // 工具栏已在 header；body 只负责消息 + 长输入
            MisterDefenderChatBody(vm: vm, skin: skin, showsToolbar: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .background(MDTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MDTheme.subtleBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .background(PanelWindowDragBlocker())
    }

    private func injectIPTipIntoChat(_ line: String) {
        vm.appendNotice(line)
    }
}

// MARK: - Helpers

private struct PanelWindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ nsView: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
