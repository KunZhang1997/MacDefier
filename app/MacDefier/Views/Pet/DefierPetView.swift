// Mr. Defier — in-window pet (knight).
// Rules: no permanent green online-dot; full-iris look; 6 moods; asset-swappable.

import AppKit
import SwiftUI

struct DefierPetView: View {
    var mood: PetMood = .idle
    var skin: PetSkin = .knight
    var size: CGFloat = 96
    /// Product rule: default OFF. Kept only for rare debug.
    var showsOnlineDot: Bool = false
    /// Track mouse for iris + slight head turn (off for tiny headers).
    var tracksLook: Bool = true
    /// When false, ignore imported pack and draw built-in skin (settings cards).
    var preferCustomPack: Bool = true
    /// AI 关：灰色但**不闭眼**（与 sleep 情绪解耦）。
    var dimmed: Bool = false
    /// Live drag motion from PetDragContainer — feeds cape cloth inertia.
    var dragMotion: PetDragMotion = .init()
    var onTap: () -> Void

    @StateObject private var lookCtrl = PetLookController()
    /// Cloth sim held as a stable reference (not ObservableObject — tick returns snapshots).
    @State private var capeSim = CapeClothSim()
    @ObservedObject private var packStore = PetPackStore.shared
    /// App 非活跃时暂停 30fps 动效（此前 paused:false 全天烧 GPU）
    @State private var appActive = true
    @State private var hostWindowVisible = true

    private var animationActive: Bool { appActive && hostWindowVisible }
    private var lookEnabled: Bool { tracksLook && size >= 48 && !dimmed && animationActive }

    /// 不可见跟眼宿主：仅在真正需要跟眼时挂载（关掉时连 NSView 都不挂）
    @ViewBuilder
    private var lookHost: some View {
        if lookEnabled {
            PetLookTrackingHost(
                controller: lookCtrl,
                enabled: true,
                petSize: size
            )
        }
    }

    var body: some View {
        // 自定义包：只播图集轨迹，不用内置跟眼/弹跳
        Group {
            if preferCustomPack, let pack = packStore.activePack {
                // 勿用 .id(…mood…)：mood 一变会拆掉整个 SpriteView，自定义宠必闪。
                // 切 mood 的动画由 PackPetSpriteView.task(id:) 内部换帧，保留 View 身份。
                PackPetSpriteView(
                    pack: pack,
                    mood: mood == .sleep ? .idle : mood,
                    size: size,
                    isActive: animationActive
                )
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .help(pack.displayName)
                    .id("pack-\(pack.id)")
            } else {
                builtinBody
            }
        }
        .saturation(dimmed ? 0.12 : 1)
        .opacity(dimmed ? 0.78 : 1)
        .animation(.easeInOut(duration: 0.22), value: dimmed)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true
            lookCtrl.setActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
            lookCtrl.setActive(false)
        }
        .background {
            PetWindowVisibilityObserver { visible in
                hostWindowVisible = visible
                lookCtrl.setActive(animationActive)
            }
        }
    }

    /// 身体 + 斗篷下摆漏出区（多留底，让披风露更多）
    private var stackHeight: CGFloat { size * 1.48 }

    private var builtinBody: some View {
        ZStack(alignment: .top) {
            petStack
                .frame(width: size * 1.12, height: stackHeight, alignment: .top)
                .background(lookHost)
                .allowsHitTesting(false)

            if showsOnlineDot {
                Circle()
                    .fill(Color(hex: 0xFF9F0A))
                    .frame(width: max(8, size * 0.1), height: max(8, size * 0.1))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .offset(x: size * 0.35, y: size * 0.04)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size * 1.12, height: stackHeight, alignment: .top)
        .contentShape(Rectangle().path(in: CGRect(x: size * 0.06, y: 0, width: size, height: size * 1.05)))
        .onTapGesture(perform: onTap)
        .help("Mr. Defier")
        .onAppear {
            appActive = NSApp.isActive
            lookCtrl.setActive(animationActive)
            lookCtrl.start(tracksLook: lookEnabled)
        }
        .onDisappear {
            lookCtrl.stop()
            capeSim.reset()
        }
        .onChange(of: mood) { _, _ in
            lookCtrl.restartBounce()
        }
        .onChange(of: tracksLook) { _, _ in
            lookCtrl.setTracksLook(lookEnabled)
        }
    }

    // MARK: - Life motion (no whole-body scale — feels stiff on an icon pet)
    // Multi-frequency float + tiny rock; mood only changes rhythm, not “grow/shrink”.

    private struct LifeMotion {
        var y: CGFloat
        var tilt: Double
        /// 0…1 for mouth / antenna pulse (facial only)
        var pulse: CGFloat
        /// Ground shadow breath (1 = resting)
        var shadow: CGFloat
    }

    private func lifeMotion(at t: TimeInterval) -> LifeMotion {
        switch mood {
        case .talk:
            // Quick lively bob + slight nod — speech energy without resizing
            let y = CGFloat(sin(t * 6.8) * 1.5 + sin(t * 11.2 + 0.4) * 0.55)
            let tilt = sin(t * 5.9) * 1.6 + sin(t * 9.1) * 0.5
            let pulse = CGFloat((sin(t * 12.5) + 1) * 0.5)
            return LifeMotion(y: y, tilt: tilt, pulse: pulse, shadow: 1 - y * 0.03)
        case .scan:
            let y = CGFloat(sin(t * 2.8) * 1.1 + sin(t * 4.6 + 1) * 0.35)
            let tilt = sin(t * 2.2) * 2.4 + sin(t * 3.5) * 0.6
            let pulse = CGFloat((sin(t * 5.5) + 1) * 0.5)
            return LifeMotion(y: y, tilt: tilt, pulse: pulse, shadow: 1 - y * 0.025)
        case .alert:
            let y = CGFloat(sin(t * 7.5) * 0.9 + sin(t * 13) * 0.25)
            let tilt = sin(t * 8.2) * 1.4
            return LifeMotion(y: y, tilt: tilt, pulse: 0.6, shadow: 1 - y * 0.02)
        case .happy:
            let y = CGFloat(sin(t * 3.6) * 1.8 + sin(t * 6.2 + 0.5) * 0.7)
            let tilt = sin(t * 3.1) * 1.8 + sin(t * 5.0) * 0.5
            return LifeMotion(y: y, tilt: tilt, pulse: 0.4, shadow: 1 - y * 0.03)
        case .sleep:
            // Slow breath — vertical only
            let y = CGFloat(sin(t * 1.05) * 0.7)
            return LifeMotion(y: y, tilt: 0, pulse: 0, shadow: 1 - y * 0.015)
        case .idle:
            // Soft hover: two sines so it never feels like a metronome
            let y = CGFloat(sin(t * 1.9) * 1.35 + sin(t * 3.15 + 0.9) * 0.55)
            let tilt = sin(t * 1.55) * 1.15 + sin(t * 2.7 + 0.4) * 0.4
            return LifeMotion(y: y, tilt: tilt, pulse: 0.3, shadow: 1 - y * 0.028)
        }
    }

    private var headTurn: Angle {
        .degrees(Double(lookCtrl.look.x) * 3.2)
    }

    private var lookVector: CGPoint {
        mood == .sleep ? .zero : lookCtrl.look
    }

    private var isBlink: Bool {
        lookCtrl.blink || mood == .sleep
    }

    private var petStack: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animationActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let life = lifeMotion(at: t)
            let snap = capeSim.tick(
                now: t,
                capeW: size * 0.92,
                capeH: size * 1.0,
                body: dragMotion,
                sleep: mood == .sleep
            )
            // Cape lag + life rock + look turn (no whole-body scale)
            let bodyAngle = Angle.degrees(
                Double(-snap.angleDeg) * 0.15 + headTurn.degrees + life.tilt
            )
            let capeAngle = Angle.degrees(Double(snap.angleDeg) + life.tilt * 0.35)

            ZStack(alignment: .top) {
                DefierCapeView(
                    size: size,
                    sleep: mood == .sleep,
                    angleDeg: snap.angleDeg,
                    hemTip: snap.hemTip,
                    breeze: snap.breeze
                )
                .offset(y: size * 0.20)
                .rotationEffect(capeAngle, anchor: UnitPoint(x: 0.5, y: 0.04))

                ZStack {
                    // Shadow softens / slides as he floats (reads as life, not scale)
                    Ellipse()
                        .fill(Color.black.opacity(0.14 * Double(max(0.55, life.shadow))))
                        .frame(
                            width: size * 0.46 * max(0.82, life.shadow),
                            height: size * 0.07
                        )
                        .offset(y: size * 0.50)
                        .blur(radius: 3)
                        .offset(x: CGFloat(life.tilt) * 0.15)

                    if let img = packResolvedImage {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size * 0.92, height: size * 0.92)
                            .rotationEffect(bodyAngle)
                            .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                            .id(packStore.activePackId ?? "builtin-\(skin.rawValue)-\(mood.rawValue)")
                    } else {
                        knightPlaceholder(pulse: life.pulse)
                            .rotationEffect(bodyAngle)
                    }
                }
                .frame(width: size, height: size * 1.05)
            }
            .offset(y: life.y)
            .frame(width: size * 1.25, height: stackHeight, alignment: .top)
        }
    }

    private var packResolvedImage: NSImage? {
        _ = packStore.activePackId
        _ = packStore.packs.count
        return PetAssets.resolvedImage(for: mood, skin: skin, preferPack: preferCustomPack)
    }

    // MARK: - 安全机器人骑士 v2
    // 调研对齐（App 吉祥物/3D icon 通例）：
    // ① 白银软金属 · 大头小身 · 圆肩甲金边  ② 表情在黑面甲内（眼±LED 嘴）
    // ③ 细天线状态灯  ④ 盔甲躯干：胸甲缝 + 腰带 + 胸盾  ⑤ 鲜红披风：前领 + 金扣链 + 扇贝下摆
    // ⑥ 金属多层反光：顶部高光 + 底部披风暖反光  ⑦ happy 眯眯笑眼

    private func knightPlaceholder(pulse: CGFloat) -> some View {
        let metalTop = Color(hex: 0xFFFFFF)
        let metalMid = Color(hex: 0xE9EEF6)
        let metalBot = Color(hex: 0xB6C2D5)

        return ZStack(alignment: .top) {
            // 细天线（根部埋进头顶）
            knightAntenna(pulse: pulse)

            // 披风前领：头下那一圈红，把披风「穿」到肩上
            capeCollar
                .offset(y: size * 0.67)

            // 盔甲躯干（胸甲缝 + 腰带 + 胸盾）
            knightTorso(metalTop: metalTop, metalMid: metalMid, metalBot: metalBot)
                .offset(y: size * 0.66)

            // 小臂 + 拳（挂在肩甲下方）
            knightArm(side: -1, metalBot: metalBot)
                .offset(x: -size * 0.315, y: size * 0.685)
            knightArm(side: 1, metalBot: metalBot)
                .offset(x: size * 0.315, y: size * 0.685)

            // 圆肩甲（金边）
            knightPauldron(metalTop: metalTop, metalMid: metalMid)
                .offset(x: -size * 0.295, y: size * 0.60)
            knightPauldron(metalTop: metalTop, metalMid: metalMid)
                .offset(x: size * 0.295, y: size * 0.60)

            // 头：一体圆壳 + 侧耳关节 + 面甲脸
            knightHead(metalTop: metalTop, metalMid: metalMid, metalBot: metalBot, pulse: pulse)
                .offset(y: size * 0.13)

            // 领口金扣链：压在头下缘 = 披风前扣
            claspChain
                .offset(y: size * 0.695)
        }
        .frame(width: size, height: size * 1.08, alignment: .top)
        // 灰显交给 dimmed；sleep 仅真休眠时再淡一点
        .opacity(mood == .sleep && !dimmed ? 0.82 : 1)
    }

    /// 面甲内 LED 嘴：idle 隐藏/极淡，talk 张口，happy 弧，sleep 点
    @ViewBuilder
    private func knightVisorMouth(pulse: CGFloat) -> some View {
        switch mood {
        case .talk:
            Capsule()
                .fill(Color(hex: 0x7EC8FF).opacity(0.9))
                .frame(width: size * 0.08, height: size * 0.035)
                .shadow(color: Color(hex: 0x3D9BFF).opacity(0.5), radius: 2)
                .scaleEffect(y: 0.88 + pulse * 0.32)
        case .happy:
            SmileShape()
                .stroke(Color(hex: 0x7EC8FF).opacity(0.85), style: StrokeStyle(lineWidth: max(1.2, size * 0.02), lineCap: .round))
                .frame(width: size * 0.1, height: size * 0.04)
                .shadow(color: Color(hex: 0x3D9BFF).opacity(0.35), radius: 1.5)
        case .alert:
            Capsule()
                .fill(Color(hex: 0xFFB340).opacity(0.9))
                .frame(width: size * 0.06, height: size * 0.028)
        case .sleep:
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: size * 0.05, height: size * 0.016)
        case .scan:
            HStack(spacing: size * 0.015) {
                Capsule().fill(Color(hex: 0x7EC8FF).opacity(0.75)).frame(width: size * 0.02, height: size * 0.03)
                Capsule().fill(Color(hex: 0x7EC8FF).opacity(0.9)).frame(width: size * 0.02, height: size * 0.04)
                Capsule().fill(Color(hex: 0x7EC8FF).opacity(0.75)).frame(width: size * 0.02, height: size * 0.03)
            }
        case .idle:
            // 默认几乎看不见，保持「干净 icon」脸
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: size * 0.06, height: size * 0.014)
        }
    }

    // MARK: - 部件

    /// 细天线 + 状态灯（根部交给头顶遮挡）
    private func knightAntenna(pulse: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.95), antennaColor],
                        center: UnitPoint(x: 0.35, y: 0.28),
                        startRadius: 0,
                        endRadius: size * 0.048
                    )
                )
                .frame(width: size * 0.095, height: size * 0.095)
                .shadow(color: antennaColor.opacity(0.6), radius: 6)
                // Status light only — soft pulse, not whole body
                .scaleEffect(mood == .talk || mood == .scan ? (0.96 + pulse * 0.12) : 1)
                .opacity(mood == .talk || mood == .scan ? (0.88 + pulse * 0.12) : 1)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xF2F5FA), Color(hex: 0x9DAABE)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.024, height: size * 0.09)
        }
    }

    /// 披风前领（红绒一圈，衔接披风与肩）
    private var capeCollar: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0xC84150), Color(hex: 0x8E2438)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size * 0.58, height: size * 0.13)
            .overlay(Capsule().stroke(Color(hex: 0x6A1828).opacity(0.45), lineWidth: 0.8))
            .shadow(color: Color(hex: 0x4A1220).opacity(0.25), radius: 3, y: 2)
    }

    /// 盔甲躯干：一体圆润 + 胸甲中缝 + 腰带 + 胸盾
    private func knightTorso(metalTop: Color, metalMid: Color, metalBot: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [metalTop, metalMid, metalBot],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.5), .clear],
                                center: UnitPoint(x: 0.5, y: 0.10),
                                startRadius: 1,
                                endRadius: size * 0.26
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color(hex: 0xD04758).opacity(0.14)],
                                startPoint: UnitPoint(x: 0.5, y: 0.68),
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.8), Color(hex: 0x8FA1B8).opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.9
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 4, y: 2)

            // 胸甲中缝（高光 + 阴影双线，装甲感）
            ZStack {
                Capsule().fill(Color.white.opacity(0.55))
                    .frame(width: 1, height: size * 0.17)
                    .offset(x: -0.6)
                Capsule().fill(Color(hex: 0x7E8CA2).opacity(0.35))
                    .frame(width: 1, height: size * 0.17)
                    .offset(x: 0.6)
            }
            .offset(y: -size * 0.05)

            // 腰带 + 铆钉
            belt
                .offset(y: size * 0.15)

            KnightShieldBadge(
                size: size * 0.165,
                colors: shieldColors,
                showCross: true
            )
            .offset(y: size * 0.005)
        }
        .frame(width: size * 0.54, height: size * 0.38)
    }

    private var belt: some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x8B99AF), Color(hex: 0x5F6E86)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.40, height: size * 0.05)
                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.6))
            HStack(spacing: size * 0.09) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color(hex: 0xE8EEF6).opacity(0.85))
                        .frame(width: size * 0.014, height: size * 0.014)
                }
            }
        }
    }

    /// 小臂 + 圆拳，顶端挂在肩甲下，略外撇
    private func knightArm(side: CGFloat, metalBot: Color) -> some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xEDF1F8), metalBot],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.08, height: size * 0.21)
                .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 0.5))
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0xF7FAFD), metalBot],
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: size * 0.05
                    )
                )
                .frame(width: size * 0.10, height: size * 0.10)
                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 0.5))
                .offset(y: size * 0.175)
        }
        .rotationEffect(.degrees(side * 6), anchor: .top)
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }

    /// 圆肩甲：银壳 + 金边内圈
    private func knightPauldron(metalTop: Color, metalMid: Color) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [metalTop, metalMid, Color(hex: 0x93A2B8)],
                    center: UnitPoint(x: 0.35, y: 0.28),
                    startRadius: 0,
                    endRadius: size * 0.12
                )
            )
            .frame(width: size * 0.21, height: size * 0.21)
            .overlay(
                Circle().stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.85), Color(hex: 0x8FA1B8).opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .overlay(
                Circle()
                    .stroke(Color(hex: 0xC99B4A).opacity(0.6), lineWidth: 1.1)
                    .padding(size * 0.022)
            )
            .shadow(color: Color(hex: 0x33405A).opacity(0.18), radius: 4, y: 2)
    }

    /// 头：一体圆壳 + 多层反光 + 侧耳关节 + 面甲脸
    private func knightHead(metalTop: Color, metalMid: Color, metalBot: Color, pulse: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [metalTop, metalMid, metalBot],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.85), .clear],
                                center: UnitPoint(x: 0.30, y: 0.16),
                                startRadius: 1,
                                endRadius: size * 0.42
                            )
                        )
                )
                .overlay(
                    // 底部披风暖反光（环境色反弹，金属才「活」）
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color(hex: 0xD04758).opacity(0.12)],
                                startPoint: UnitPoint(x: 0.5, y: 0.66),
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.9), Color(hex: 0x8FA1B8).opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .frame(width: size * 0.76, height: size * 0.60)
                .shadow(color: Color(hex: 0x33405A).opacity(0.20), radius: 10, y: 5)

            // 侧耳关节（机器人读点）
            HStack {
                knightEarCap
                Spacer(minLength: 0)
                knightEarCap
            }
            .frame(width: size * 0.80)
            .offset(y: size * 0.02)

            // 黑面甲 = 整张「脸」（玻璃光泽 + 金属包边）
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x1B2438), Color(hex: 0x070B13)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.10), .clear],
                                    startPoint: UnitPoint(x: 0.2, y: 0),
                                    endPoint: UnitPoint(x: 0.55, y: 0.55)
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(hex: 0x4A5878).opacity(0.9), Color(hex: 0x0A0E18).opacity(0.9)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.1
                            )
                    )

                VStack(spacing: size * 0.022) {
                    HStack(spacing: size * 0.055) {
                        knightEye
                        knightEye
                    }
                    // LED 小嘴：只在面甲内，不挂到下巴外面
                    knightVisorMouth(pulse: pulse)
                }
                .padding(.vertical, size * 0.02)
            }
            .frame(width: size * 0.50, height: size * 0.30)
            .offset(y: size * 0.02)
        }
        .frame(width: size * 0.88, height: size * 0.60)
    }

    private var knightEarCap: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(hex: 0xE8EEF7), Color(hex: 0x97A5BA)],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 0,
                    endRadius: size * 0.055
                )
            )
            .frame(width: size * 0.10, height: size * 0.10)
            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.7))
            .overlay(
                Circle()
                    .fill(Color(hex: 0x6E7C92).opacity(0.55))
                    .frame(width: size * 0.032, height: size * 0.032)
            )
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    }

    /// 领口金扣链：两枚金扣 + 下垂链弧
    private var claspChain: some View {
        ZStack {
            ChainArcShape()
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: 0xF6DC9A), Color(hex: 0xB98E46)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: max(1.2, size * 0.013), lineCap: .round)
                )
                .frame(width: size * 0.33, height: size * 0.045)
                .offset(y: size * 0.008)
            HStack(spacing: size * 0.275) {
                claspDisc
                claspDisc
            }
        }
    }

    private var claspDisc: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(hex: 0xF9E7B8), Color(hex: 0xC89B4C)],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 0,
                    endRadius: size * 0.03
                )
            )
            .frame(width: size * 0.055, height: size * 0.055)
            .overlay(Circle().stroke(Color(hex: 0x8A6A30).opacity(0.55), lineWidth: 0.7))
            .shadow(color: Color(hex: 0x5A3A10).opacity(0.25), radius: 1.5, y: 1)
    }

    private var knightEye: some View {
        PetEyeView(
            size: size * 0.125,
            look: lookVector,
            blink: isBlink,
            sleep: mood == .sleep,
            spark: lookCtrl.spark,
            cheerful: mood == .happy,
            irisColors: [Color(hex: 0xB0DCFF), Color(hex: 0x3A7BFF), Color(hex: 0x0A1840)]
        )
    }

    private var antennaColor: Color {
        switch mood {
        case .alert: return Color(hex: 0xFF9F0A)
        case .talk: return Color(hex: 0x64D2FF)
        case .scan: return Color(hex: 0x5E5CE6)
        case .happy: return Color(hex: 0x30D158)
        case .sleep: return Color(hex: 0xAEAEB2)
        case .idle: return Color(hex: 0x3D9BFF)
        }
    }

    private var shieldColors: [Color] {
        switch mood {
        case .alert: return [Color(hex: 0xFFD60A), Color(hex: 0xFF9F0A)]
        case .talk, .scan: return [Color(hex: 0x8EC5FF), Color(hex: 0x5E5CE6)]
        case .happy: return [Color(hex: 0x63E6A0), Color(hex: 0x0A84FF)]
        case .sleep: return [Color(hex: 0xC7C7CC), Color(hex: 0x8E8E93)]
        case .idle: return [Color(hex: 0x8EC5FF), Color(hex: 0x5B8CFF), Color(hex: 0x5E5CE6)]
        }
    }
}

private struct PetWindowVisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onChange: (Bool) -> Void
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

        func attach(to window: NSWindow?) {
            guard self.window !== window else { report(); return }
            detach()
            self.window = window
            guard let window else { onChange(false); return }
            let center = NotificationCenter.default
            // These public notifications cover visibility changes without relying on
            // private/nonexistent didOrderOnScreen/OffScreen constants.
            for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
            report()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = nil
        }

        private func report() {
            onChange(window.map { $0.isVisible && !$0.isMiniaturized } ?? false)
        }
    }
}

// MARK: - 斗篷
// 原则（动画 follow-through + 图标尺度）：
// • 轮廓永远是披风：颈窄（藏头后）、过肩线才张开、鲜红渐变、扇贝下摆
// • 上半钉死（头两侧不露红）；只让下摆轻微滞后，禁止侧向「翅膀」式外扩
// • 金扣链在领口前方（body 侧 claspChain），披风本体只管布料
// • 保持体积/比例（volume），不做 squash 成怪形

private struct DefierCapeView: View {
    var size: CGFloat
    var sleep: Bool
    var angleDeg: CGFloat
    var hemTip: CGFloat
    var breeze: CGFloat

    var body: some View {
        let capeW = size * 0.98
        let capeH = size * 1.02
        let frameW = size * 1.15
        let frameH = size * 1.18
        // Mild shape bias only (hem tip), not a silhouette destroyer
        let tip = max(-1, min(1, hemTip + breeze * 0.15))

        ZStack(alignment: .top) {
            IconCapeShape(hemTip: tip, breeze: breeze)
                .fill(Color(hex: 0x5E1424).opacity(0.25))
                .blur(radius: 2)
                .offset(y: 2.5)
                .frame(width: capeW, height: capeH)

            IconCapeShape(hemTip: tip, breeze: breeze)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0xEA6A74),
                            Color(hex: 0xD64755),
                            Color(hex: 0xAE2C40),
                            Color(hex: 0x8A1F32)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    IconCapeShape(hemTip: tip, breeze: breeze)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.30),
                                    Color.white.opacity(0.06),
                                    .clear,
                                    Color.black.opacity(0.14)
                                ],
                                startPoint: UnitPoint(x: 0.32, y: 0),
                                endPoint: UnitPoint(x: 0.68, y: 1)
                            )
                        )
                )
                .overlay(
                    IconCapeFolds(hemTip: tip)
                        .stroke(Color(hex: 0x701C2E).opacity(0.32), lineWidth: 1)
                )
                .overlay(
                    IconCapeShape(hemTip: tip, breeze: breeze)
                        .stroke(Color(hex: 0x64182A).opacity(0.35), lineWidth: 1)
                )
                .shadow(color: Color(hex: 0x4A1220).opacity(0.25), radius: 3.5, y: 2)
                .frame(width: capeW, height: capeH)
        }
        .frame(width: frameW, height: frameH, alignment: .top)
        .opacity(sleep ? 0.52 : 0.94)
        .allowsHitTesting(false)
    }
}

/// Stable icon cape: neck pin · shoulder flare · curved hem.
/// Only the FREE hem shifts a little (follow-through). Upper half barely moves.
private struct IconCapeShape: Shape {
    var hemTip: CGFloat // −1…1 lag of free end
    var breeze: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(hemTip, breeze) }
        set {
            hemTip = newValue.first
            breeze = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height

        // 结构点：颈窄并藏在头后 → 过肩线才张开 → 身侧顺下 → 扇贝下摆
        // 关键：y≈0.40 以下才允许变宽，保证头两侧不露红（披风是「穿」的，不是背景板）
        let neckL = CGPoint(x: w * 0.42, y: h * 0.006)
        let neckR = CGPoint(x: w * 0.58, y: h * 0.006)
        let upperR = CGPoint(x: w * 0.68, y: h * 0.30)
        let upperL = CGPoint(x: w * 0.32, y: h * 0.30)
        let shoulderR = CGPoint(x: w * 0.90, y: h * 0.52)
        let shoulderL = CGPoint(x: w * 0.10, y: h * 0.52)

        // 只有下摆自由摆动（follow-through），上半钉死
        let s = hemTip * w * 0.10 + breeze * w * 0.04
        let wave = breeze * h * 0.020
        let wave2 = breeze * h * 0.011

        let sideR = CGPoint(x: w * 0.955 + s * 0.15, y: h * 0.68 + wave2 * 0.3)
        let sideL = CGPoint(x: w * 0.045 + s * 0.15, y: h * 0.68 - wave2 * 0.2)

        // 扇贝下摆：三个下垂弧瓣，中瓣最低
        let hemR = CGPoint(x: w * 0.895 + s, y: h * 0.84 + wave)
        let dipR = CGPoint(x: w * 0.750 + s * 0.9, y: h * 0.935 + wave * 0.8 + wave2)
        let peakR = CGPoint(x: w * 0.615 + s * 0.7, y: h * 0.890 + wave * 0.6)
        let dipC = CGPoint(x: w * 0.490 + s * 0.5, y: h * 0.960 + wave * 0.95 + wave2)
        let peakL = CGPoint(x: w * 0.365 + s * 0.35, y: h * 0.890 + wave * 0.6 - wave2 * 0.4)
        let dipL = CGPoint(x: w * 0.230 + s * 0.9, y: h * 0.935 + wave * 0.8 - wave2 * 0.6)
        let hemL = CGPoint(x: w * 0.085 + s, y: h * 0.84 + wave * 0.9)

        var p = Path()
        p.move(to: neckL)
        p.addLine(to: neckR)
        p.addQuadCurve(to: upperR, control: CGPoint(x: w * 0.66, y: h * 0.12))
        p.addCurve(
            to: shoulderR,
            control1: CGPoint(x: w * 0.72, y: h * 0.40),
            control2: CGPoint(x: w * 0.84, y: h * 0.46)
        )
        p.addCurve(
            to: sideR,
            control1: CGPoint(x: w * 0.945, y: h * 0.56),
            control2: CGPoint(x: w * 0.960 + s * 0.1, y: h * 0.62)
        )
        p.addCurve(
            to: hemR,
            control1: CGPoint(x: w * 0.950 + s * 0.3, y: h * 0.74),
            control2: CGPoint(x: w * 0.920 + s * 0.6, y: h * 0.79)
        )
        // 扇贝边：瓣间控制点外挑，形成圆润波谷
        p.addQuadCurve(to: dipR, control: CGPoint(x: w * 0.838 + s, y: h * 0.920 + wave))
        p.addQuadCurve(to: peakR, control: CGPoint(x: w * 0.680 + s * 0.8, y: h * 0.955 + wave * 0.8))
        p.addQuadCurve(to: dipC, control: CGPoint(x: w * 0.552 + s * 0.6, y: h * 0.928 + wave * 0.9))
        p.addQuadCurve(to: peakL, control: CGPoint(x: w * 0.428 + s * 0.45, y: h * 0.955 + wave * 0.85))
        p.addQuadCurve(to: dipL, control: CGPoint(x: w * 0.300 + s * 0.7, y: h * 0.928 + wave * 0.8))
        p.addQuadCurve(to: hemL, control: CGPoint(x: w * 0.148 + s, y: h * 0.920 + wave))
        p.addCurve(
            to: sideL,
            control1: CGPoint(x: w * 0.065 + s * 0.6, y: h * 0.79),
            control2: CGPoint(x: w * 0.045 + s * 0.3, y: h * 0.74)
        )
        p.addCurve(
            to: shoulderL,
            control1: CGPoint(x: w * 0.040 + s * 0.1, y: h * 0.62),
            control2: CGPoint(x: w * 0.055, y: h * 0.56)
        )
        p.addCurve(
            to: upperL,
            control1: CGPoint(x: w * 0.16, y: h * 0.46),
            control2: CGPoint(x: w * 0.28, y: h * 0.40)
        )
        p.addQuadCurve(to: neckL, control: CGPoint(x: w * 0.34, y: h * 0.12))
        p.closeSubpath()
        return p
    }
}

private struct IconCapeFolds: Shape {
    var hemTip: CGFloat

    var animatableData: CGFloat {
        get { hemTip }
        set { hemTip = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let s = hemTip * w * 0.04
        var path = Path()
        // 三条褶皱自肩线落到三个下摆波谷
        let folds: [(CGFloat, CGFloat)] = [(0.46, 0.27), (0.50, 0.49), (0.54, 0.72)]
        for (topT, botT) in folds {
            path.move(to: CGPoint(x: w * topT, y: h * 0.32))
            path.addQuadCurve(
                to: CGPoint(x: w * botT + s, y: h * 0.90),
                control: CGPoint(x: w * ((topT + botT) * 0.5) + s * 0.3, y: h * 0.58)
            )
        }
        return path
    }
}

// MARK: - Eye (full iris; glance stretches eye outline)

private struct PetEyeView: View {
    var size: CGFloat
    var look: CGPoint
    var blink: Bool
    var sleep: Bool
    var spark: Bool
    /// happy：眯眯笑弧眼（∩），盖过普通虹膜
    var cheerful: Bool = false
    // irisColors may have 2 or 3 stops
    var irisColors: [Color] = [
        Color(red: 0.12, green: 0.14, blue: 0.28),
        Color(red: 0.08, green: 0.1, blue: 0.2)
    ]

    var body: some View {
        let eyeW = size * (1.0 + abs(look.x) * 0.12)
        let eyeH = blink || sleep ? size * 0.18 : size * (1.05 - abs(look.x) * 0.06)
        let irisS = size * 0.72
        let maxOff = size * 0.28
        let ix = look.x * maxOff
        let iy = -look.y * maxOff * 0.85
        let gradientColors: [Color] = {
            if irisColors.count >= 3 { return irisColors }
            return irisColors + [Color.black.opacity(0.9)]
        }()

        ZStack {
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: 0xEEF2FF)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: eyeW, height: eyeH)
                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)

            if cheerful && !blink && !sleep {
                HappyEyeArc()
                    .stroke(
                        Color(hex: 0x141C2E),
                        style: StrokeStyle(lineWidth: max(1.6, size * 0.15), lineCap: .round)
                    )
                    .frame(width: size * 0.60, height: size * 0.32)
                    .offset(y: size * 0.04)
            } else if !blink && !sleep {
                ZStack {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: gradientColors,
                                center: UnitPoint(x: 0.35, y: 0.32),
                                startRadius: 0,
                                endRadius: irisS * 0.55
                            )
                        )
                        .frame(width: irisS, height: irisS * 1.02)
                    Ellipse()
                        .fill(Color.black.opacity(0.88))
                        .frame(width: irisS * 0.36, height: irisS * 0.4)
                    Circle()
                        .fill(Color.white.opacity(spark ? 0.98 : 0.85))
                        .frame(width: irisS * 0.3, height: irisS * 0.3)
                        .offset(x: irisS * 0.14, y: -irisS * 0.16)
                }
                .offset(x: ix, y: iy)
            }
        }
        .frame(width: size * 1.15, height: size * 1.15)
    }
}

/// Compact chest shield badge with optional cross (matches wireframe knight).
private struct KnightShieldBadge: View {
    var size: CGFloat
    var colors: [Color]
    var showCross: Bool = true

    var body: some View {
        ZStack {
            ShieldShape()
                .fill(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: size, height: size * 1.12)
                .overlay(
                    ShieldShape()
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                        .frame(width: size, height: size * 1.12)
                )
                .shadow(color: Color(hex: 0x2850A0).opacity(0.28), radius: 3, y: 1)

            // 金边外圈（骑士纹章感）
            ShieldShape()
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: 0xF2DA9E), Color(hex: 0xB98E46)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.1
                )
                .frame(width: size * 1.14, height: size * 1.14 * 1.12)

            if showCross {
                // 十字 / plus（与目标稿一致）
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: size * 0.14, height: size * 0.48)
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: size * 0.42, height: size * 0.13)
                    .offset(y: -size * 0.02)
            }
        }
    }
}

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addCurve(
            to: CGPoint(x: w, y: h * 0.18),
            control1: CGPoint(x: w * 0.78, y: 0),
            control2: CGPoint(x: w, y: h * 0.06)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.5, y: h),
            control1: CGPoint(x: w, y: h * 0.55),
            control2: CGPoint(x: w * 0.72, y: h * 0.88)
        )
        p.addCurve(
            to: CGPoint(x: 0, y: h * 0.18),
            control1: CGPoint(x: w * 0.28, y: h * 0.88),
            control2: CGPoint(x: 0, y: h * 0.55)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.5, y: 0),
            control1: CGPoint(x: 0, y: h * 0.06),
            control2: CGPoint(x: w * 0.22, y: 0)
        )
        p.closeSubpath()
        return p
    }
}

private struct SmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return p
    }
}

/// happy 眯眯笑眼（∩ 弧）
private struct HappyEyeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.35)
        )
        return p
    }
}

/// 领口金链下垂弧
private struct ChainArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY * 1.6)
        )
        return p
    }
}
