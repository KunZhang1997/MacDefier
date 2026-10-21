// MenuBarController — 菜单栏常驻
// · 有监控：Stats Mini 形态 CPU/MEM（template）
// · 无监控：Mr. Defier 品牌脸（彩色大头+面甲+蓝天线，非小盾线稿）

import AppKit
import Combine
import SwiftUI
import MonitorKit

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    static let defaultsKey = "macdefier.menubar.enabled"
    static let showCPUKey = "macdefier.menubar.showCPU"
    static let showRAMKey = "macdefier.menubar.showRAM"

    private var item: NSStatusItem?
    private var panel: NSPopover?
    private var cancellable: AnyCancellable?
    private var freshnessTimer: AnyCancellable?
    private let monitor = MonitorService.shared
    private var lastSignature = ""

    private override init() {
        super.init()
    }

    var isVisible: Bool { item != nil }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
    }

    func restoreFromDefaults() {
        let enabled = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
        setEnabled(enabled)
    }

    /// 设置页切换 CPU/内存显示后刷新
    func refreshFromDefaults() {
        lastSignature = ""
        if item != nil { installSnapshotSubscription() }
        updateSamplingDemand()
        refresh()
    }

    private var showCPU: Bool {
        // 默认关：无监控时菜单栏就是 Mr. Defier 品牌脸
        if UserDefaults.standard.object(forKey: Self.showCPUKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: Self.showCPUKey)
    }

    private var showRAM: Bool {
        if UserDefaults.standard.object(forKey: Self.showRAMKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: Self.showRAMKey)
    }

    private func install() {
        if item != nil {
            refresh()
            return
        }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.imagePosition = .imageOnly
        status.button?.toolTip = "MacDefier · Mr. Defier"
        status.button?.target = self
        status.button?.action = #selector(togglePanel)
        item = status

        installSnapshotSubscription()
        updateSamplingDemand()
        refresh()
    }

    private func installSnapshotSubscription() {
        cancellable?.cancel()
        freshnessTimer?.cancel()
        // Capture the current flags for removeDuplicates, and rebuild this
        // subscription whenever Settings changes either flag.
        let showCPU = self.showCPU
        let showRAM = self.showRAM
        let metrics = monitor.$snapshot.map { (snapshot: MonitorSnapshot) -> (Int?, Int?) in
            let cpu = showCPU && snapshot.cpuIsFresh() ? snapshot.cpu.map { Int(($0.totalUsage * 100).rounded()) } : nil
            let ram = showRAM && snapshot.ramIsFresh() ? snapshot.ram.map { Int(($0.usage * 100).rounded()) } : nil
            return (cpu, ram)
        }
        cancellable = metrics
            .removeDuplicates(by: { $0 == $1 })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
        freshnessTimer = (showCPU || showRAM) ? Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.refresh() } : nil
    }

    private func uninstall() {
        closePanel()
        cancellable?.cancel()
        cancellable = nil
        freshnessTimer?.cancel()
        freshnessTimer = nil
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        lastSignature = ""
        updateSamplingDemand()
    }

    private func refresh() {
        guard let button = item?.button else { return }

        let cpuFrac = showCPU && monitor.snapshot.cpuIsFresh() ? monitor.snapshot.cpu?.totalUsage : nil
        let ramFrac = showRAM && monitor.snapshot.ramIsFresh() ? monitor.snapshot.ram?.usage : nil

        let sig = signature(cpu: cpuFrac, ram: ramFrac)
        guard sig != lastSignature else { return }
        lastSignature = sig

        let pack = MenuBarIconRenderer.renderPack(cpu: cpuFrac, ram: ramFrac)
        button.image = pack.image
        button.image?.isTemplate = pack.isTemplate
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.imagePosition = .imageOnly
        button.appearsDisabled = false
        // 禁系统把 status 画成带边按钮
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor

        var tipParts: [String] = ["MacDefier · Mr. Defier"]
        if let c = cpuFrac {
            tipParts.append(String(format: "CPU %.0f%%", c * 100))
        } else if showCPU {
            tipParts.append("CPU —")
        }
        if let r = ramFrac {
            tipParts.append(String(format: "MEM %.0f%%", r * 100))
        } else if showRAM {
            tipParts.append("MEM —")
        }
        button.toolTip = tipParts.joined(separator: " · ")
    }

    private func updateSamplingDemand() {
        monitor.setMenuBarMetrics(
            cpu: item != nil && showCPU,
            ram: item != nil && showRAM
        )
    }

    private func signature(cpu: Double?, ram: Double?) -> String {
        func bucket(_ v: Double?) -> String {
            guard let v else { return "-" }
            return String(Int((v * 100).rounded()))
        }
        return "\(showCPU ? 1 : 0)\(showRAM ? 1 : 0)|\(bucket(cpu))|\(bucket(ram))"
    }

    func showPanel() {
        guard panel?.isShown != true else { return }
        togglePanel()
    }

    @objc private func togglePanel() {
        guard let button = item?.button else { return }
        if panel?.isShown == true {
            closePanel()
            return
        }

        let height = min(728, max(360, (button.window?.screen?.visibleFrame.height ?? 800) - 36))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: height)
        popover.contentViewController = NSHostingController(rootView: MenuBarPanelView(
            monitor: monitor,
            height: height,
            navigate: { [weak self] route, tab in
                self?.closePanel()
                let nav = AppNavigator.shared
                nav.route = route
                nav.misterOpen = false
                if let tab { nav.monitorTab = tab }
                MainWindowRouter.openMainWindow()
            }
        ))
        panel = popover
        monitor.setMenuBarPanelVisible(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKey()
        } else {
            closePanel()
        }
    }

    private func closePanel() {
        panel?.performClose(nil)
        panel = nil
        monitor.setMenuBarPanelVisible(false)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, panel === closed else { return }
        panel = nil
        monitor.setMenuBarPanelVisible(false)
    }
}

// MARK: - Icon drawing

/// 菜单栏 status 图
enum MenuBarIconRenderer {
    struct Pack {
        let image: NSImage
        /// true = 指标 template；false = Mr. Defier 彩色脸
        let isTemplate: Bool
    }

    private static let barH: CGFloat = 18
    private static let padX: CGFloat = 2
    private static let gap: CGFloat = 5
    private static let chipW: CGFloat = 34
    /// 无监控时 Mr. Defier 半身（菜单栏点尺寸）
    private static let brandSide: CGFloat = 18

    static func render(cpu: Double?, ram: Double?) -> NSImage {
        renderPack(cpu: cpu, ram: ram).image
    }

    static func renderPack(cpu: Double?, ram: Double?) -> Pack {
        var chips: [(label: String, value: Double)] = []
        if let cpu { chips.append(("CPU", min(1, max(0, cpu)))) }
        if let ram { chips.append(("MEM", min(1, max(0, ram)))) }

        if chips.isEmpty {
            return Pack(image: mrDefierBrandImage(), isTemplate: true)
        }

        let width = padX * 2 + CGFloat(chips.count) * chipW + CGFloat(max(0, chips.count - 1)) * gap
        let size = NSSize(width: width, height: barH)
        let img = NSImage(size: size, flipped: false) { _ in
            var x = padX
            for chip in chips {
                drawChip(label: chip.label, value: chip.value, originX: x)
                x += chipW + gap
            }
            return true
        }
        img.isTemplate = true
        return Pack(image: img, isTemplate: true)
    }

    /// 设置页预览：品牌脸保留彩色；指标仍按 template 着色
    static func previewImage(cpu: Double?, ram: Double?, height: CGFloat = 22) -> NSImage {
        let pack = renderPack(cpu: cpu, ram: ram)
        let base = pack.image
        let size = NSSize(width: max(base.size.width + 4, 22), height: height)
        let out = NSImage(size: size, flipped: false) { rect in
            let target = NSRect(
                x: (rect.width - base.size.width) / 2,
                y: (rect.height - base.size.height) / 2,
                width: base.size.width,
                height: base.size.height
            )
            if pack.isTemplate {
                // 预览底上用 label 色
                base.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
                // recolor via sourceIn
                NSColor.labelColor.set()
                target.fill(using: .sourceIn)
            } else {
                base.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        out.isTemplate = false
        return out
    }

    // MARK: Mr. Defier brand (no metrics)
    // 禁止从 AppIcon 抽图（蓝圆角方底会变成黑框且发糊）
    // 直接画「半身大头」黑白剪影 template，对齐 v4b 构图

    private static var cachedBrand: NSImage?

    /// 无监控主 icon：半个 Mr. Defier 大头近景 · monochrome · 无方框
    static func mrDefierBrandImage(side: CGFloat = brandSide) -> NSImage {
        if let cachedBrand, abs(cachedBrand.size.width - side) < 0.5 {
            return cachedBrand
        }
        let img = drawHalfBodyTemplate(side: side)
        cachedBrand = img
        return img
    }

    /// @3x 矢量栅格 → 利落 template；透明底，无圆角底板
    private static func drawHalfBodyTemplate(side: CGFloat) -> NSImage {
        let scale: CGFloat = 3
        let px = max(54, Int((side * scale).rounded()))
        let point = side

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        // 点尺寸 = 菜单栏逻辑尺寸；像素 = @3x
        rep.size = NSSize(width: point, height: point)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ng = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        NSGraphicsContext.current = ng
        ng.imageInterpolation = .high
        // 允许轻微抗锯齿，但形状用实心填充保持边缘干净
        ng.shouldAntialias = true
        ng.cgContext.setAllowsAntialiasing(true)
        ng.cgContext.setShouldAntialias(true)

        let bounds = NSRect(x: 0, y: 0, width: point, height: point)
        ng.cgContext.clear(CGRect(origin: .zero, size: CGSize(width: point, height: point)))
        drawHalfBodySilhouette(in: bounds)

        let img = NSImage(size: NSSize(width: point, height: point))
        img.addRepresentation(rep)
        img.isTemplate = true
        // 明确逻辑尺寸，避免 status bar 拉伸发糊
        img.size = NSSize(width: point, height: point)
        return img
    }

    /// 半身构图（对齐 AppIcon v4b）：大头占满 · 底边横切上胸 · 天线 · 宽面甲双眼
    /// 画在透明底上；**绝不**画圆角方底板
    private static func drawHalfBodySilhouette(in rect: NSRect) {
        let s = min(rect.width, rect.height)
        // 四周留 1pt 气口，避免贴边被 status bar 裁糊
        let pad = s * 0.04
        let ox = rect.minX + (rect.width - s) / 2 + pad
        let oy = rect.minY + (rect.height - s) / 2 + pad
        let u = s - pad * 2
        let ink = NSColor.black

        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: ox + x * u, y: oy + y * u, width: w * u, height: h * u)
        }

        // 1) 上胸：从底边切入（半身裁切），无整身
        ink.setFill()
        let chest = NSBezierPath(
            roundedRect: R(0.16, -0.06, 0.68, 0.34),
            xRadius: u * 0.20,
            yRadius: u * 0.16
        )
        chest.fill()

        // 2) 大圆头（主体，对齐 icon 大头）
        ink.setFill()
        let head = NSBezierPath(ovalIn: R(0.06, 0.12, 0.88, 0.82))
        head.fill()

        // 3) 天线杆 + 球（贴顶）
        ink.setStroke()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: ox + 0.50 * u, y: oy + 0.88 * u))
        stem.line(to: NSPoint(x: ox + 0.50 * u, y: oy + 0.94 * u))
        stem.lineWidth = max(1.6, u * 0.07)
        stem.lineCapStyle = .round
        stem.stroke()
        ink.setFill()
        NSBezierPath(ovalIn: R(0.39, 0.90, 0.22, 0.16)).fill()

        // 4) 宽面甲：抠透明窗（开窗），再画双眼实心
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: R(0.20, 0.38, 0.60, 0.32),
                xRadius: u * 0.13,
                yRadius: u * 0.13
            ).fill()
            ctx.restoreGState()
        }

        // 双眼（面甲内）
        ink.setFill()
        let eye: CGFloat = 0.16
        let ey: CGFloat = 0.46
        NSBezierPath(ovalIn: R(0.28, ey, eye, eye)).fill()
        NSBezierPath(ovalIn: R(0.56, ey, eye, eye)).fill()

        // 面甲细描边（加强开窗可读，仍是单色）
        ink.setStroke()
        let visor = NSBezierPath(
            roundedRect: R(0.20, 0.38, 0.60, 0.32),
            xRadius: u * 0.13,
            yRadius: u * 0.13
        )
        visor.lineWidth = max(1.0, u * 0.045)
        visor.stroke()
    }

    // MARK: Metric chips (template)

    private static func drawChip(label: String, value: Double, originX: CGFloat) {
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let color = NSColor.black

        let labelStr = NSAttributedString(string: label, attributes: [
            .font: labelFont,
            .foregroundColor: color.withAlphaComponent(0.85),
        ])
        let labelSize = labelStr.size()
        labelStr.draw(at: NSPoint(x: originX + (chipW - labelSize.width) / 2, y: 10))

        let pct = String(format: "%.0f%%", value * 100)
        let valueStr = NSAttributedString(string: pct, attributes: [
            .font: valueFont,
            .foregroundColor: color,
        ])
        let valueSize = valueStr.size()
        valueStr.draw(at: NSPoint(x: originX + (chipW - valueSize.width) / 2, y: 0))

        let barY: CGFloat = 0.5
        let barHeight: CGFloat = 1.5
        let barWidth = chipW - 2
        let track = NSRect(x: originX + 1, y: barY, width: barWidth, height: barHeight)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 0.75, yRadius: 0.75).fill()

        let fillW = max(1.5, barWidth * CGFloat(value))
        let fill = NSRect(x: originX + 1, y: barY, width: fillW, height: barHeight)
        color.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 0.75, yRadius: 0.75).fill()
    }
}
