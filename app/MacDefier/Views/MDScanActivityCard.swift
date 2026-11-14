import AppKit
import CleanupKit
import SwiftUI

enum MDScanArtworkKind { case cleanup, aiTools, disk, software }

/// A presentation clock only. Scanner events own stages, counts and completion.
/// Keeping it in the page preserves the frame when the card becomes compact.
@MainActor
final class MDScanAnimationClock: ObservableObject {
    @Published private(set) var stageID: String?
    private var session: Date?
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?
    private var activeOwner: ObjectIdentifier?

    func sync(_ journey: ScanJourney, animating: Bool, owner: ObjectIdentifier, now: Date = Date()) {
        if session != journey.startedAt {
            session = journey.startedAt
            accumulated = 0
            runningSince = nil
            activeOwner = nil
            stageID = nil
        }
        if let active = journey.activeID, stageID != active { stageID = active }
        if animating {
            activeOwner = owner
            if runningSince == nil { runningSince = now }
        } else if journey.status == .stopped || activeOwner == owner {
            freeze(now: now)
            activeOwner = nil
        }
    }

    private func freeze(now: Date = Date()) {
        if let since = runningSince { accumulated += max(0, now.timeIntervalSince(since)) }
        runningSince = nil
    }

    /// An outgoing large/compact card must not stop its already-visible replacement.
    func relinquish(_ owner: ObjectIdentifier, now: Date = Date()) {
        guard activeOwner == owner else { return }
        freeze(now: now)
        activeOwner = nil
    }

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
}

@MainActor
private final class MDScanAnimationOwner: ObservableObject {}

/// Start/resume is the entire result-card surface, not an additional toolbar button.
/// No scanner, selection or destructive action is owned by this view.
struct MDScanActivityCard: View {
    let kind: MDScanArtworkKind
    let journey: ScanJourney
    @ObservedObject var clock: MDScanAnimationClock
    let title: String
    var detail: String? = nil
    var compact = false
    var activeOverride = false
    var action: (() -> Void)? = nil
    var stop: (() -> Void)? = nil
    let identifier: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var hovered = false
    @StateObject private var animationOwner = MDScanAnimationOwner()

    private var isScanningActive: Bool {
        journey.status == .running || activeOverride
    }

    /// Animate briskly while scanning, and gently on idle/ready hero cards so vector
    /// artwork is consistently alive across workbenches (paused when stopped or hidden).
    private var animating: Bool {
        visible && scenePhase == .active && !reduceMotion && journey.status != .stopped
            && (isScanningActive || !usesCompactLayout || hovered)
    }

    /// Running and paused work stays compact even before the first result.
    /// A completed/discarded scan does not make an empty start entry compact.
    private var usesCompactLayout: Bool {
        compact || isScanningActive || journey.status == .stopped
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    composition.contentShape(RoundedRectangle(cornerRadius: MDTheme.resultCardRadius))
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityHint(detail ?? "")
            } else {
                composition
            }
        }
        .frame(maxWidth: .infinity)
        .background(hovered && action != nil ? MDTheme.surfaceInset : MDTheme.surface,
                    in: RoundedRectangle(cornerRadius: MDTheme.resultCardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MDTheme.resultCardRadius)
                .strokeBorder(contrast == .increased ? MDTheme.border : MDTheme.subtleBorder,
                              lineWidth: contrast == .increased ? 1.5 : 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: MDTheme.resultCardRadius))
        .onHover { hovered = $0; synchronize() }
        .accessibilityIdentifier(identifier)
        .onAppear { visible = true; synchronize() }
        .onDisappear { visible = false; clock.relinquish(ObjectIdentifier(animationOwner)) }
        .onChange(of: journey) { _, _ in synchronize() }
        .onChange(of: activeOverride) { _, _ in synchronize() }
        .onChange(of: scenePhase) { _, _ in synchronize() }
        .onChange(of: reduceMotion) { _, _ in synchronize() }
    }

    @ViewBuilder private var composition: some View {
        if usesCompactLayout {
            HStack(spacing: 14) {
                artwork.frame(width: 126, height: 80)
                invitation(alignment: .leading)
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(height: 96)
        } else {
            GeometryReader { geometry in
                let width = min(360, max(140, min(geometry.size.width - 48,
                    (geometry.size.height - 100) * 1.5)))
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    artwork.frame(width: width, height: width / 1.5)
                    invitation(alignment: .center)
                        .layoutPriority(1)
                    accessory
                    Spacer(minLength: 0)
                }
                .padding(16).frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minHeight: 220, idealHeight: 360, maxHeight: .infinity)
        }
    }

    private var artwork: some View {
        let interval = isScanningActive ? (1.0 / 30.0) : (1.0 / 24.0)
        return TimelineView(.animation(minimumInterval: interval, paused: !animating)) { context in
            let rawElapsed = reduceMotion ? 0 : clock.elapsed(at: context.date)
            let speed = isScanningActive ? 1.0 : (hovered ? 0.65 : 0.35)
            MDScanVectorArtwork(
                kind: kind,
                journey: journey,
                stageID: clock.stageID,
                elapsed: rawElapsed * speed,
                isScanning: isScanningActive,
                reduceMotion: reduceMotion,
                opaqueSupports: reduceTransparency,
                compact: usesCompactLayout,
                isDark: colorScheme == .dark
            )
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func invitation(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(title).font(usesCompactLayout ? .callout.weight(.semibold) : .title3.weight(.semibold))
                .lineLimit(usesCompactLayout ? 2 : nil)
                .foregroundStyle(MDTheme.label).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .help(title)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(MDTheme.secondary)
                    .lineLimit(usesCompactLayout ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    @ViewBuilder private var accessory: some View {
        if let stop {
            Button(L10n.t("scan.stop"), action: stop)
                .buttonStyle(.bordered).controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(identifier + ".stop")
        }
    }

    private func synchronize() {
        clock.sync(journey, animating: animating, owner: ObjectIdentifier(animationOwner))
    }
}

/// 100% resolution-independent vector/SVG-path artwork for all four scan workbenches.
/// Crisp at both large hero size (360×240) and compact header size (126×80).
private struct MDScanVectorArtwork: View {
    let kind: MDScanArtworkKind
    let journey: ScanJourney
    let stageID: String?
    let elapsed: TimeInterval
    let isScanning: Bool
    let reduceMotion: Bool
    let opaqueSupports: Bool
    let compact: Bool
    let isDark: Bool

    // Vector palette adaptive to light/dark themes
    private var trayFill: Color {
        isDark ? Color(hex: 0x2A3038).opacity(opaqueSupports ? 1 : 0.88)
               : Color(hex: 0xEAECEF).opacity(opaqueSupports ? 1 : 0.92)
    }
    private var trayWell: Color {
        isDark ? Color(hex: 0x1E232A) : Color(hex: 0xDDE1E7)
    }
    private var trayStroke: Color {
        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.11)
    }
    private var cardFill: Color {
        isDark ? Color(hex: 0x353C46) : Color(hex: 0xFFFFFF)
    }
    private var cardAltFill: Color {
        isDark ? Color(hex: 0x2E3540) : Color(hex: 0xF7F8FA)
    }
    private var cardStroke: Color {
        isDark ? Color.white.opacity(0.22) : Color(hex: 0xC6CCD4)
    }
    private var lineMuted: Color {
        isDark ? Color.white.opacity(0.22) : Color(hex: 0xCBD2DC)
    }
    private var accent: Color {
        isDark ? Color(hex: 0x4DA3FF) : Color(hex: 0x007AFF)
    }
    private var emerald: Color {
        isDark ? Color(hex: 0x34D399) : Color(hex: 0x10B981)
    }
    private var amber: Color {
        isDark ? Color(hex: 0xFBBF24) : Color(hex: 0xF59E0B)
    }

    var body: some View {
        Canvas { context, size in
            switch kind {
            case .cleanup: drawCleanup(context, size)
            case .aiTools: drawAITools(context, size)
            case .disk: drawDisk(context, size)
            case .software: drawSoftware(context, size)
            }
        }
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
    }

    private func unit(_ fraction: Double, _ size: CGSize) -> Double {
        max(1, min(size.width, size.height * 1.5) * fraction)
    }

    // MARK: 1. Cleanup — Vector Tray + Riffling Document Stack + Sweeping Magnifying Lens

    private func drawCleanup(_ context: GraphicsContext, _ size: CGSize) {
        let u = min(size.width, size.height * 1.5)
        let strokeW = compact ? 1.25 : 1.6
        let phase = reduceMotion ? 0.18 : (elapsed / 2.4).truncatingRemainder(dividingBy: 1.0)
        let angle = phase * .pi * 2
        let sweepX = sin(angle)
        let sweepY = cos(angle * 2) * 0.5

        // Soft shadow base
        let shadow = rect(0.14, 0.78, 0.72, 0.11, size)
        context.fill(Path(ellipseIn: shadow), with: .color(Color.black.opacity(isDark ? 0.28 : 0.07)))

        // Back tray rim
        let trayOuter = rect(0.13, 0.44, 0.74, 0.40, size)
        let trayCorner = u * 0.07
        context.fill(Path(roundedRect: trayOuter, cornerRadius: trayCorner), with: .color(trayFill))
        context.stroke(Path(roundedRect: trayOuter, cornerRadius: trayCorner), with: .color(trayStroke), lineWidth: strokeW)

        let innerWell = trayOuter.insetBy(dx: u * 0.045, dy: u * 0.045)
        context.fill(Path(roundedRect: innerWell, cornerRadius: max(4, trayCorner - 3)), with: .color(trayWell))

        // Three crisp vector document cards fanning gently
        let cardSpecs: [(dx: Double, dy: Double, rot: Double, tint: Color)] = [
            (-0.10 - sweepX * 0.025, 0.18, -8 - sweepX * 2.5, cardAltFill),
            (0.00 + sweepX * 0.035, 0.13 - abs(sweepX) * 0.025, 1.5 + sweepX * 3.0, cardFill),
            (0.10 - sweepX * 0.020, 0.19, 7 - sweepX * 2.0, cardAltFill)
        ]

        for (idx, spec) in cardSpecs.enumerated() {
            let cw = size.width * 0.34
            let ch = size.height * 0.52
            let center = CGPoint(x: size.width * (0.48 + spec.dx), y: size.height * (0.22 + spec.dy))
            var layer = context
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(spec.rot))
            let box = CGRect(x: -cw / 2, y: -ch / 2, width: cw, height: ch)
            let cr = max(4, u * 0.045)
            layer.fill(Path(roundedRect: box, cornerRadius: cr), with: .color(spec.tint))
            layer.stroke(Path(roundedRect: box, cornerRadius: cr), with: .color(cardStroke), lineWidth: strokeW)

            // Vector document header pill & lines
            let pillH = max(2.2, ch * 0.09)
            let pill = CGRect(x: box.minX + cw * 0.14, y: box.minY + ch * 0.15, width: cw * 0.42, height: pillH)
            let headerTint = idx == 1 ? accent.opacity(0.82) : emerald.opacity(0.70)
            layer.fill(Path(roundedRect: pill, cornerRadius: pillH / 2), with: .color(headerTint))

            for row in 0..<3 {
                let lw = cw * (row == 2 ? 0.48 : 0.70)
                let lineRect = CGRect(
                    x: box.minX + cw * 0.14,
                    y: box.minY + ch * (0.36 + Double(row) * 0.16),
                    width: lw,
                    height: max(1.6, ch * 0.055)
                )
                layer.fill(Path(roundedRect: lineRect, cornerRadius: 1.5), with: .color(lineMuted))
            }
        }

        // Front lip of tray (overlapping bottom of cards for 3D depth)
        let frontLip = rect(0.13, 0.66, 0.74, 0.18, size)
        context.fill(Path(roundedRect: frontLip, cornerRadius: trayCorner), with: .color(trayFill))
        context.stroke(Path(roundedRect: frontLip, cornerRadius: trayCorner), with: .color(trayStroke), lineWidth: strokeW)

        // Sweeping vector magnifying glass (large, crisp motion visible even at 126×80)
        let lensRadius = u * (compact ? 0.175 : 0.165)
        let lensCenter = CGPoint(
            x: size.width * (0.50 + sweepX * 0.17),
            y: size.height * (0.45 + sweepY * 0.10)
        )
        let lensRect = CGRect(
            x: lensCenter.x - lensRadius,
            y: lensCenter.y - lensRadius,
            width: lensRadius * 2,
            height: lensRadius * 2
        )

        // Handle
        var handleLayer = context
        handleLayer.translateBy(x: lensCenter.x, y: lensCenter.y)
        handleLayer.rotate(by: .degrees(38 + sweepX * 6))
        let handleW = max(3.5, lensRadius * 0.30)
        let handleRect = CGRect(x: -handleW / 2, y: lensRadius * 0.88, width: handleW, height: lensRadius * 0.92)
        handleLayer.fill(
            Path(roundedRect: handleRect, cornerRadius: handleW / 2),
            with: .color(isDark ? Color(hex: 0x94A3B8) : Color(hex: 0x475569))
        )

        // Lens glass + magnified scan highlight
        context.fill(
            Path(ellipseIn: lensRect),
            with: .color(accent.opacity(isDark ? 0.20 : 0.13))
        )
        var innerLens = context
        innerLens.clip(to: Path(ellipseIn: lensRect.insetBy(dx: 2, dy: 2)))
        let scanBarY = lensRect.minY + lensRect.height * (0.28 + (sweepX + 1) * 0.22)
        let scanBar = CGRect(x: lensRect.minX + lensRadius * 0.32, y: scanBarY, width: lensRadius * 1.36, height: max(2.2, lensRadius * 0.18))
        innerLens.fill(Path(roundedRect: scanBar, cornerRadius: 2), with: .color(accent.opacity(0.85)))
        let scanSubBar = CGRect(x: lensRect.minX + lensRadius * 0.32, y: scanBarY + max(4, lensRadius * 0.30), width: lensRadius * 0.92, height: max(1.8, lensRadius * 0.13))
        innerLens.fill(Path(roundedRect: scanSubBar, cornerRadius: 1.5), with: .color(emerald.opacity(0.80)))

        // Specular highlight arc + crisp outer ring
        var highlight = Path()
        highlight.addArc(
            center: lensCenter,
            radius: lensRadius * 0.74,
            startAngle: .degrees(205),
            endAngle: .degrees(260),
            clockwise: false
        )
        context.stroke(highlight, with: .color(.white.opacity(isDark ? 0.45 : 0.75)), style: StrokeStyle(lineWidth: max(1.5, strokeW), lineCap: .round))
        context.stroke(
            Path(ellipseIn: lensRect),
            with: .color(accent),
            lineWidth: compact ? 2.0 : 2.5
        )
    }

    // MARK: 2. AI Tools — Vector 5-Slot Organizer + Arcing Card + Illuminated Bays

    private func drawAITools(_ context: GraphicsContext, _ size: CGSize) {
        let ids = ["appData", "cliData", "conversations", "models", "worktrees"]
        let symbols = ["macwindow", "terminal", "bubble.left.and.bubble.right", "cube.box", "arrow.triangle.branch"]
        let labels = ["scan.art.apps", "scan.art.cli", "scan.art.chats", "scan.art.models", "scan.art.worktrees"]
        let centers = [0.16, 0.33, 0.50, 0.67, 0.84]
        let u = min(size.width, size.height * 1.5)
        let strokeW = compact ? 1.2 : 1.5

        let cycleIndex = Int((elapsed / 1.35).truncatingRemainder(dividingBy: Double(ids.count)))
        let explicitActive = ids.firstIndex { "scan.stage." + $0 == (journey.activeID ?? stageID) }
        let activeIdx = explicitActive ?? (reduceMotion ? 2 : cycleIndex)
        let verifying = (journey.activeID ?? stageID) == "scan.stage.verify"

        // Organizer dock body
        let dock = rect(0.06, 0.54, 0.88, 0.36, size)
        let dockCorner = max(6, u * 0.065)
        context.fill(Path(roundedRect: dock, cornerRadius: dockCorner), with: .color(trayFill))
        context.stroke(Path(roundedRect: dock, cornerRadius: dockCorner), with: .color(trayStroke), lineWidth: strokeW)

        // Flying vector card arcing into the active slot
        let phase = reduceMotion ? 0.65 : (elapsed / 1.35).truncatingRemainder(dividingBy: 1.0)
        let t = min(1, max(0, (phase - 0.08) / 0.76))
        let eased = t * t * (3 - 2 * t)
        let targetX = verifying ? 0.50 : centers[activeIdx]
        let cardCenterX = (0.50 + (targetX - 0.50) * eased) * size.width
        let cardCenterY = (0.22 + 0.24 * eased - sin(eased * .pi) * 0.11) * size.height
        let cardW = size.width * (compact ? 0.22 : 0.20)
        let cardH = size.height * (compact ? 0.26 : 0.25)

        var cardLayer = context
        cardLayer.translateBy(x: cardCenterX, y: cardCenterY)
        cardLayer.rotate(by: .degrees((targetX - 0.50) * 18 * eased))
        let cardBox = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
        let cardCorner = max(4, u * 0.04)
        cardLayer.fill(Path(roundedRect: cardBox, cornerRadius: cardCorner), with: .color(cardFill))
        cardLayer.stroke(Path(roundedRect: cardBox, cornerRadius: cardCorner), with: .color(verifying ? emerald : accent), lineWidth: compact ? 1.5 : 1.8)

        let flySymbolName = verifying ? "checkmark.shield.fill" : symbols[activeIdx]
        var flySym = cardLayer.resolve(Image(systemName: flySymbolName))
        flySym.shading = .color(verifying ? emerald : accent)
        let symH = cardH * 0.50
        let symW = symH * 1.1
        cardLayer.draw(flySym, in: CGRect(x: -symW / 2, y: -symH / 2, width: symW, height: symH))

        // Five vector bays
        for index in centers.indices {
            let isCurrent = !verifying && index == activeIdx && (isScanning || !reduceMotion)
            let isDone = journey.completedIDs.contains("scan.stage." + ids[index]) || verifying
            let bayW = 0.145
            let bayY = compact ? 0.60 : 0.59
            let bayH = compact ? 0.24 : 0.25
            let bay = rect(centers[index] - bayW / 2, bayY, bayW, bayH, size)
            let bayCorner = max(4, u * 0.04)

            let fill: Color = isCurrent
                ? accent.opacity(isDark ? 0.28 : 0.16)
                : (isDone ? emerald.opacity(isDark ? 0.22 : 0.14) : cardAltFill)
            let border: Color = isCurrent
                ? accent
                : (isDone ? emerald.opacity(0.85) : cardStroke)

            context.fill(Path(roundedRect: bay, cornerRadius: bayCorner), with: .color(fill))
            context.stroke(Path(roundedRect: bay, cornerRadius: bayCorner), with: .color(border), lineWidth: isCurrent ? (compact ? 1.6 : 2.0) : 1.0)

            var icon = context.resolve(Image(systemName: symbols[index]))
            icon.shading = .color(isCurrent ? accent : (isDone ? emerald : (isDark ? Color.white.opacity(0.75) : Color(hex: 0x475569))))
            let iconSize = min(bay.width * 0.52, bay.height * (compact ? 0.62 : 0.44))
            let iconY = compact ? (bay.midY - iconSize / 2) : (bay.minY + bay.height * 0.14)
            context.draw(icon, in: CGRect(x: bay.midX - iconSize / 2, y: iconY, width: iconSize, height: iconSize))

            if !compact {
                context.draw(
                    Text(L10n.t(labels[index]))
                        .font(.system(size: max(8, size.width * 0.024), weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? accent : (isDark ? Color.white.opacity(0.78) : Color(hex: 0x334155))),
                    at: CGPoint(x: bay.midX, y: bay.minY + bay.height * 0.78)
                )
            }
        }
    }

    // MARK: 3. Disk — Vector Aluminum SSD + Pulse Bridge + Folder with Rising Storage Blocks

    private func drawDisk(_ context: GraphicsContext, _ size: CGSize) {
        let u = min(size.width, size.height * 1.5)
        let strokeW = compact ? 1.3 : 1.6
        let phase = reduceMotion ? 0.35 : (elapsed / 2.2).truncatingRemainder(dividingBy: 1.0)
        let wave = (1 - cos(phase * .pi * 2)) / 2

        // Vector bridge trace between SSD and Folder
        var bridge = Path()
        let bridgeY = size.height * 0.63
        bridge.move(to: CGPoint(x: size.width * 0.42, y: bridgeY))
        bridge.addLine(to: CGPoint(x: size.width * 0.56, y: bridgeY))
        context.stroke(bridge, with: .color(lineMuted), style: StrokeStyle(lineWidth: compact ? 1.6 : 2.0, lineCap: .round, dash: [3, 3]))

        if !reduceMotion {
            let dotX = size.width * (0.42 + phase * 0.14)
            let dotR = compact ? 2.4 : 3.2
            context.fill(Path(ellipseIn: CGRect(x: dotX - dotR, y: bridgeY - dotR, width: dotR * 2, height: dotR * 2)), with: .color(accent))
        }

        // Left: Crisp vector external SSD enclosure
        let ssd = rect(0.08, 0.38, 0.35, 0.44, size)
        let ssdCorner = max(6, u * 0.065)
        context.fill(Path(roundedRect: ssd, cornerRadius: ssdCorner), with: .color(trayFill))
        context.stroke(Path(roundedRect: ssd, cornerRadius: ssdCorner), with: .color(cardStroke), lineWidth: strokeW)

        let ssdTop = ssd.insetBy(dx: u * 0.035, dy: u * 0.04)
        context.fill(Path(roundedRect: ssdTop, cornerRadius: max(4, ssdCorner - 2)), with: .color(cardFill))

        // SSD glyph + pulsing LED
        var driveIcon = context.resolve(Image(systemName: "internaldrive"))
        driveIcon.shading = .color(isDark ? Color.white.opacity(0.70) : Color(hex: 0x475569))
        let dSize = min(ssd.width, ssd.height) * 0.38
        context.draw(driveIcon, in: CGRect(x: ssd.midX - dSize / 2, y: ssd.midY - dSize * 0.62, width: dSize, height: dSize))

        let ledR = compact ? 2.8 : 3.6
        let ledCenter = CGPoint(x: ssd.maxX - u * 0.075, y: ssd.maxY - u * 0.075)
        let ledColor = isScanning ? emerald : accent
        if !reduceMotion {
            let haloR = ledR * (1.4 + wave * 1.1)
            context.fill(
                Path(ellipseIn: CGRect(x: ledCenter.x - haloR, y: ledCenter.y - haloR, width: haloR * 2, height: haloR * 2)),
                with: .color(ledColor.opacity(0.28 * (1 - wave * 0.5)))
            )
        }
        context.fill(
            Path(ellipseIn: CGRect(x: ledCenter.x - ledR, y: ledCenter.y - ledR, width: ledR * 2, height: ledR * 2)),
            with: .color(ledColor)
        )

        // Right: Folder back tab + rising treemap storage cards + folder front
        let folderBack = rect(0.52, 0.28, 0.39, 0.54, size)
        let folderTab = rect(0.52, 0.22, 0.16, 0.12, size)
        let folderTintBack = isDark ? Color(hex: 0x2563EB).opacity(0.55) : Color(hex: 0x60A5FA).opacity(0.55)
        context.fill(Path(roundedRect: folderTab, cornerRadius: max(3, u * 0.035)), with: .color(folderTintBack))
        context.fill(Path(roundedRect: folderBack, cornerRadius: max(6, u * 0.06)), with: .color(folderTintBack))

        // Rising storage cards (clearly visible motion at compact size!)
        let blockColors = [accent, emerald, amber]
        for idx in 0..<3 {
            let localPhase = reduceMotion ? 0.4 : ((elapsed / 2.2) + Double(idx) * 0.22).truncatingRemainder(dividingBy: 1.0)
            let lift = (1 - cos(localPhase * .pi * 2)) / 2
            let blockRect = rect(
                0.555 + Double(idx) * 0.095,
                0.24 - lift * 0.13,
                0.13,
                0.34,
                size
            )
            let cr = max(3, u * 0.035)
            context.fill(Path(roundedRect: blockRect, cornerRadius: cr), with: .color(cardFill))
            context.stroke(Path(roundedRect: blockRect, cornerRadius: cr), with: .color(blockColors[idx]), lineWidth: strokeW)
            let cap = CGRect(x: blockRect.minX + 2, y: blockRect.minY + 2, width: blockRect.width - 4, height: max(4, blockRect.height * 0.28))
            context.fill(Path(roundedRect: cap, cornerRadius: max(2, cr - 1)), with: .color(blockColors[idx].opacity(0.82)))
        }

        // Folder front pocket
        let folderFront = rect(0.52, 0.44, 0.39, 0.38, size)
        let folderCorner = max(6, u * 0.06)
        let folderTintFront = isDark ? Color(hex: 0x3B82F6).opacity(0.88) : Color(hex: 0x3B82F6).opacity(0.84)
        context.fill(Path(roundedRect: folderFront, cornerRadius: folderCorner), with: .color(folderTintFront))
        context.stroke(Path(roundedRect: folderFront, cornerRadius: folderCorner), with: .color(.white.opacity(0.28)), lineWidth: 1.0)
    }

    // MARK: 4. Software — Vector 3×2 App Squircle Grid + Gliding Inspector Reticle & Tile Lift

    private func drawSoftware(_ context: GraphicsContext, _ size: CGSize) {
        let u = min(size.width, size.height * 1.5)
        let strokeW = compact ? 1.2 : 1.5
        let symbols = ["app.badge", "hammer.fill", "paintbrush.fill", "terminal.fill", "play.rectangle.fill", "gearshape.fill"]
        let tints: [Color] = [
            accent,
            Color(hex: 0x6366F1),
            Color(hex: 0xEC4899),
            emerald,
            amber,
            Color(hex: 0x14B8A6)
        ]

        // Shelf backdrop
        let shelf = rect(0.10, 0.14, 0.80, 0.72, size)
        let shelfCorner = max(7, u * 0.07)
        context.fill(Path(roundedRect: shelf, cornerRadius: shelfCorner), with: .color(trayFill))
        context.stroke(Path(roundedRect: shelf, cornerRadius: shelfCorner), with: .color(trayStroke), lineWidth: strokeW)

        // Smooth continuous scan cursor across 6 tiles (0..<6)
        let rawCursor = reduceMotion ? 0.0 : ((elapsed / 2.7).truncatingRemainder(dividingBy: 1.0) * 6.0)
        let activeTile = Int(rawCursor) % 6
        let frac = rawCursor - floor(rawCursor)
        let eased = frac * frac * (3 - 2 * frac)
        let nextTile = (activeTile + 1) % 6

        func tileCenter(_ idx: Int) -> CGPoint {
            let col = idx % 3
            let row = idx / 3
            let x = 0.27 + Double(col) * 0.23
            let y = 0.34 + Double(row) * 0.32
            return CGPoint(x: x * size.width, y: y * size.height)
        }

        let tileSide = min(size.width * 0.165, size.height * 0.255)
        let tileCorner = tileSide * 0.26

        for idx in 0..<6 {
            let base = tileCenter(idx)
            let proximity: Double = {
                if reduceMotion { return idx == 0 ? 1 : 0 }
                if idx == activeTile { return 1 - eased }
                if idx == nextTile { return eased }
                return 0
            }()
            let liftY = proximity * (compact ? 3.5 : 5.5)
            let scale = 1.0 + proximity * 0.09
            let side = tileSide * scale
            let box = CGRect(x: base.x - side / 2, y: base.y - side / 2 - liftY, width: side, height: side)

            context.fill(Path(roundedRect: box, cornerRadius: tileCorner * scale), with: .color(cardFill))
            context.stroke(
                Path(roundedRect: box, cornerRadius: tileCorner * scale),
                with: .color(proximity > 0.25 ? tints[idx] : cardStroke),
                lineWidth: proximity > 0.25 ? (compact ? 1.6 : 2.0) : 1.0
            )

            var sym = context.resolve(Image(systemName: symbols[idx]))
            sym.shading = .color(tints[idx].opacity(0.75 + proximity * 0.25))
            let iconSide = side * 0.50
            context.draw(sym, in: CGRect(x: box.midX - iconSide / 2, y: box.midY - iconSide / 2, width: iconSide, height: iconSide))
        }

        // Gliding vector inspection reticle frame
        if !reduceMotion {
            let c0 = tileCenter(activeTile)
            let c1 = tileCenter(nextTile)
            let rx = c0.x + (c1.x - c0.x) * eased
            let ry = c0.y + (c1.y - c0.y) * eased - (compact ? 3.5 : 5.5) * (1 - abs(eased - 0.5) * 0.6)
            let frameSide = tileSide * 1.24
            let frameRect = CGRect(x: rx - frameSide / 2, y: ry - frameSide / 2, width: frameSide, height: frameSide)
            context.stroke(
                Path(roundedRect: frameRect, cornerRadius: tileCorner * 1.25),
                with: .color(accent.opacity(isScanning ? 0.95 : 0.65)),
                style: StrokeStyle(lineWidth: compact ? 1.8 : 2.2, dash: isScanning ? [] : [5, 3])
            )
        }
    }
}
