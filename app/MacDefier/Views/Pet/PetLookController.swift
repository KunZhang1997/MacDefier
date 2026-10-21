// Look controller + NSView tracking.
// In-window: eyes continuously follow mouse (poll-based, not click-only).
// Mouse left the window: autonomous "self-play" glances.

import AppKit
import Combine
import SwiftUI

@MainActor
final class PetLookController: ObservableObject {
    @Published var look: CGPoint = .zero
    @Published var blink: Bool = false
    @Published var spark: Bool = false
    @Published var bounce: Bool = false
    /// true when cursor is inside the host window frame
    @Published private(set) var mouseInsideWindow: Bool = true

    /// Window-space center of the pet (Cocoa: origin bottom-left).
    var petCenterInWindow: CGPoint?
    weak var hostWindow: NSWindow?
    var petSize: CGFloat = 92

    private var blinkTask: Task<Void, Never>?
    private var trackTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var enabled = false
    private var active = true
    private var isIdlePlaying = false

    func start(tracksLook: Bool) {
        bounce = true
        enabled = tracksLook
        resumeIfNeeded()
    }

    func stop() {
        enabled = false
        trackTask?.cancel()
        trackTask = nil
        stopIdlePlay(resetLook: false)
        blinkTask?.cancel()
        blinkTask = nil
    }

    func restartBounce() {
        bounce = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.bounce = true
        }
    }

    func setTracksLook(_ on: Bool) {
        enabled = on
        if on, active {
            startTrackingLoop()
        } else {
            trackTask?.cancel()
            trackTask = nil
            stopIdlePlay(resetLook: true)
        }
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active {
            resumeIfNeeded()
        } else {
            trackTask?.cancel()
            trackTask = nil
            stopIdlePlay(resetLook: false)
            blinkTask?.cancel()
            blinkTask = nil
        }
    }

    private func resumeIfNeeded() {
        guard active else { return }
        startBlink()
        if enabled { startTrackingLoop() }
    }

    /// Called from tracking NSView with window coordinates (both Cocoa, y-up).
    func updateLook(mouseInWindow: CGPoint, petCenterInWindow: CGPoint, petSize: CGFloat) {
        guard enabled else { return }
        self.petCenterInWindow = petCenterInWindow
        self.petSize = petSize
        if !mouseInsideWindow {
            mouseInsideWindow = true
            stopIdlePlay(resetLook: false)
        }
        applyTrackedLook(mouseInWindow: mouseInWindow, petCenterInWindow: petCenterInWindow, petSize: petSize)
    }

    private func applyTrackedLook(mouseInWindow: CGPoint, petCenterInWindow: CGPoint, petSize: CGFloat) {
        let dx = mouseInWindow.x - petCenterInWindow.x
        let dy = mouseInWindow.y - petCenterInWindow.y
        // 距离归一化：略远仍能看清方向
        let maxR = max(petSize * 1.35, 48)
        var nx = max(-1, min(1, dx / maxR))
        var ny = max(-1, min(1, dy / maxR))
        let mag = hypot(nx, ny)
        // 死区：几乎对准宠物中心时回正，避免抖
        if mag < 0.06 {
            nx = 0
            ny = 0
        }
        setLook(CGPoint(x: nx, y: ny))
    }

    private func setLook(_ next: CGPoint) {
        // 小阈值过滤噪声；足够小以保证跟手
        if abs(next.x - look.x) > 0.004 || abs(next.y - look.y) > 0.004 {
            look = next
        }
    }

    // MARK: - Continuous tracking (poll screen mouse → window coords)

    /// 不依赖 mouseMoved 事件（滚动区/部分控件会吞掉 moved，导致只剩点击才更新）。
    private func startTrackingLoop() {
        guard active else { return }
        trackTask?.cancel()
        // 先确保窗口接收 moved（备用）
        if let w = hostWindow ?? NSApp.keyWindow {
            w.acceptsMouseMovedEvents = true
        }
        trackTask = Task { [weak self] in
            // ~30fps：够跟手，又不抢主线程
            let interval: UInt64 = 33_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await MainActor.run {
                    self?.tickTrack()
                }
            }
        }
    }

    private func tickTrack() {
        guard enabled else { return }
        // App 非活跃（隐藏/焦点在别家）时不跟眼：30fps 轮询没必要白跑
        guard NSApp.isActive else { return }
        // 尽量用宠物所在窗；否则 keyWindow
        let win = hostWindow ?? NSApp.keyWindow
        guard let win else { return }
        win.acceptsMouseMovedEvents = true
        hostWindow = win

        guard let center = petCenterInWindow else { return }

        let screenPt = NSEvent.mouseLocation
        let frame = win.frame.insetBy(dx: 1, dy: 1)
        let inside = frame.contains(screenPt)

        if inside {
            if !mouseInsideWindow {
                mouseInsideWindow = true
                stopIdlePlay(resetLook: false)
            }
            // 屏幕坐标 → 窗口坐标（Cocoa，原点左下）
            let mouseInWindow = win.convertPoint(fromScreen: screenPt)
            applyTrackedLook(
                mouseInWindow: mouseInWindow,
                petCenterInWindow: center,
                petSize: petSize
            )
        } else if mouseInsideWindow {
            mouseInsideWindow = false
            startIdlePlay()
        }
    }

    // MARK: - Idle self-play (mouse outside)

    private func startIdlePlay() {
        guard active, enabled, !isIdlePlaying else { return }
        isIdlePlaying = true
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            await self?.animateLook(to: .zero, duration: 0.35)
            while !Task.isCancelled {
                guard let self else { break }
                let playing = await MainActor.run { self.isIdlePlaying && self.enabled }
                if !playing { break }

                let action = Int.random(in: 0...4)
                switch action {
                case 0:
                    await self.animateLook(to: self.randomGlance(radius: 0.55...0.9), duration: 0.45)
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 900_000_000...1_600_000_000))
                case 1:
                    await self.animateLook(to: CGPoint(x: -0.7, y: 0.1), duration: 0.28)
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    await self.animateLook(to: CGPoint(x: 0.7, y: 0.05), duration: 0.32)
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    await self.animateLook(to: .zero, duration: 0.3)
                case 2:
                    await self.animateLook(to: CGPoint(x: CGFloat.random(in: -0.25...0.25), y: 0.65), duration: 0.4)
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 700_000_000...1_200_000_000))
                    await self.animateLook(to: .zero, duration: 0.35)
                case 3:
                    await self.animateLook(
                        to: CGPoint(
                            x: CGFloat.random(in: -0.15...0.15),
                            y: CGFloat.random(in: -0.1...0.15)
                        ),
                        duration: 0.5
                    )
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 1_400_000_000...2_400_000_000))
                default:
                    await self.animateLook(to: self.randomGlance(radius: 0.35...0.7), duration: 0.38)
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 500_000_000...1_000_000_000))
                    await self.animateLook(to: .zero, duration: 0.4)
                }
                try? await Task.sleep(nanoseconds: UInt64.random(in: 200_000_000...600_000_000))
            }
        }
    }

    private func stopIdlePlay(resetLook: Bool) {
        isIdlePlaying = false
        idleTask?.cancel()
        idleTask = nil
        if resetLook {
            withAnimation(.easeOut(duration: 0.25)) {
                look = .zero
            }
        }
    }

    private func randomGlance(radius: ClosedRange<CGFloat>) -> CGPoint {
        let r = CGFloat.random(in: radius)
        let angle = CGFloat.random(in: 0...(2 * .pi))
        return CGPoint(
            x: max(-1, min(1, cos(angle) * r)),
            y: max(-1, min(1, sin(angle) * r * 0.85))
        )
    }

    private func animateLook(to target: CGPoint, duration: TimeInterval) async {
        let steps = max(4, Int(duration / 0.03))
        let start = await MainActor.run { look }
        for i in 1...steps {
            if Task.isCancelled { return }
            // 若中途鼠标回到窗内，idle 会被停掉；此处仍写 look 无妨
            let t = CGFloat(i) / CGFloat(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let p = CGPoint(
                x: start.x + (target.x - start.x) * e,
                y: start.y + (target.y - start.y) * e
            )
            await MainActor.run { self.look = p }
            try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
        }
        await MainActor.run { self.look = target }
    }

    // MARK: - Blink

    private func startBlink() {
        blinkTask?.cancel()
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 2_400_000_000...3_600_000_000))
                guard let self, !Task.isCancelled else { break }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.07)) { self.blink = true }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.07)) { self.blink = false }
                    self.spark.toggle()
                }
            }
        }
    }

    deinit {
        blinkTask?.cancel()
        trackTask?.cancel()
        idleTask?.cancel()
    }
}

/// Invisible host: reports pet center in window coords for the tracking loop.
struct PetLookTrackingHost: NSViewRepresentable {
    @ObservedObject var controller: PetLookController
    var enabled: Bool
    var petSize: CGFloat

    func makeNSView(context: Context) -> PetLookNSView {
        let v = PetLookNSView()
        v.controller = controller
        v.petSize = petSize
        v.enabled = enabled
        return v
    }

    func updateNSView(_ nsView: PetLookNSView, context: Context) {
        nsView.controller = controller
        nsView.petSize = petSize
        nsView.enabled = enabled
        nsView.publishCenter()
        if enabled {
            nsView.window?.acceptsMouseMovedEvents = true
            controller.hostWindow = nsView.window
            controller.petSize = petSize
            controller.setTracksLook(true)
        }
    }

    final class PetLookNSView: NSView {
        weak var controller: PetLookController?
        var petSize: CGFloat = 92
        var enabled: Bool = true

        override var isFlipped: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            controller?.hostWindow = window
            publishCenter()
        }

        override func layout() {
            super.layout()
            publishCenter()
        }

        func publishCenter() {
            guard let window else { return }
            let local = NSPoint(x: bounds.midX, y: bounds.midY)
            let inWindow = convert(local, to: nil)
            controller?.petCenterInWindow = inWindow
            controller?.hostWindow = window
            controller?.petSize = petSize
            window.acceptsMouseMovedEvents = true
        }
    }
}
