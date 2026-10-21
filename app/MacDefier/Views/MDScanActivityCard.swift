import AppKit
import CleanupKit
import SwiftUI

enum MDScanArtworkKind { case cleanup, aiTools, disk }

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
        } else if journey.status != .running || activeOwner == owner {
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
    var action: (() -> Void)? = nil
    var stop: (() -> Void)? = nil
    let identifier: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var hovered = false
    @StateObject private var animationOwner = MDScanAnimationOwner()

    private var animating: Bool {
        visible && scenePhase == .active && !reduceMotion
            && journey.status == .running && journey.activeID != nil
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
        .onHover { hovered = $0 }
        .accessibilityIdentifier(identifier)
        .onAppear { visible = true; synchronize() }
        .onDisappear { visible = false; clock.relinquish(ObjectIdentifier(animationOwner)) }
        .onChange(of: journey) { _, _ in synchronize() }
        .onChange(of: scenePhase) { _, _ in synchronize() }
        .onChange(of: reduceMotion) { _, _ in synchronize() }
    }

    @ViewBuilder private var composition: some View {
        if compact {
            HStack(spacing: 14) {
                artwork.frame(width: 116, height: 78)
                invitation(alignment: .leading)
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 94)
        } else {
            GeometryReader { geometry in
                let width = min(360, max(130, min(geometry.size.width - 48,
                    (geometry.size.height - 100) * 1.5)))
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    artwork.frame(width: width, height: width / 1.5)
                    invitation(alignment: .center)
                    accessory
                    Spacer(minLength: 0)
                }
                .padding(16).frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minHeight: 220, idealHeight: 360, maxHeight: .infinity)
        }
    }

    private var artwork: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
            MDScanArtwork(kind: kind, journey: journey, stageID: clock.stageID,
                          elapsed: reduceMotion ? 0 : clock.elapsed(at: context.date),
                          reduceMotion: reduceMotion, opaqueSupports: reduceTransparency,
                          compact: compact)
        }
        .accessibilityHidden(true).allowsHitTesting(false)
    }

    private func invitation(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(title).font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(MDTheme.label).fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(MDTheme.secondary)
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

/// The approved bitmap materials are composed in a bounded native canvas.
/// Only local objects move. Nothing vanishes or implies automatic deletion.
private struct MDScanArtwork: View {
    let kind: MDScanArtworkKind
    let journey: ScanJourney
    let stageID: String?
    let elapsed: TimeInterval
    let reduceMotion: Bool
    let opaqueSupports: Bool
    let compact: Bool

    var body: some View {
        Canvas { context, size in
            switch kind {
            case .cleanup: cleanup(context, size)
            case .aiTools: aiTools(context, size)
            case .disk: disk(context, size)
            }
        }
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    private func image(_ name: String, in rect: CGRect, rotation: Double = 0, context: GraphicsContext) {
        var layer = context
        layer.translateBy(x: rect.midX, y: rect.midY)
        layer.rotate(by: .degrees(rotation))
        layer.draw(Image(name), in: CGRect(x: -rect.width / 2, y: -rect.height / 2,
                                          width: rect.width, height: rect.height))
    }

    private func support(in bounds: CGRect, context: GraphicsContext) {
        guard opaqueSupports else { return }
        context.fill(Path(roundedRect: bounds, cornerRadius: 8), with: .color(Color(hex: 0xD4D1C9)))
    }

    private func cleanup(_ context: GraphicsContext, _ size: CGSize) {
        support(in: rect(0.16, 0.49, 0.7, 0.29, size), context: context)
        image("ScanCleanupTray", in: rect(0, 0, 1, 1, size), context: context)
        let phase = reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 3.8) / 3.8
        let travel = sin(phase * .pi * 2)
        image("ScanPaper", in: rect(0.18 + travel * 0.035, 0.01 - travel * 0.012, 0.62, 0.62, size),
              rotation: reduceMotion ? -1 : travel * 3 - 1, context: context)
        let lens = rect(0.28 - travel * 0.022, 0.17 - travel * 0.02, 0.75, 0.75, size)
        let circle = CGRect(x: lens.minX + lens.width * 0.17, y: lens.minY + lens.height * 0.08,
                            width: lens.width * 0.42, height: lens.height * 0.63)
        var magnified = context
        magnified.clip(to: Path(ellipseIn: circle))
        magnified.opacity = 0.85
        image("ScanPaper", in: CGRect(x: circle.minX - circle.width * 0.66,
              y: circle.minY - circle.height * 0.7, width: circle.width * 2.3, height: circle.height * 2.3), context: magnified)
        image("ScanCleanupLens", in: lens, context: context)
    }

    private func aiTools(_ context: GraphicsContext, _ size: CGSize) {
        let ids = ["appData", "cliData", "conversations", "models", "worktrees"]
        let symbols = ["macwindow", "terminal", "bubble.left.and.bubble.right", "externaldrive", "arrow.triangle.branch"]
        let labels = ["scan.art.apps", "scan.art.cli", "scan.art.chats", "scan.art.models", "scan.art.worktrees"]
        let centers = [0.17, 0.335, 0.5, 0.665, 0.83]
        let active = ids.firstIndex { "scan.stage." + $0 == (journey.activeID ?? stageID) }
        let verifying = (journey.activeID ?? stageID) == "scan.stage.verify"
        support(in: rect(0.06, 0.58, 0.88, 0.25, size), context: context)
        image("ScanAIOrganizer", in: rect(0, 0, 1, 1, size), context: context)

        let target = active.map { centers[$0] } ?? 0.5
        let phase = elapsed.truncatingRemainder(dividingBy: 1.65) / 1.65
        let travel = reduceMotion ? 1 : min(1, max(0, (phase - 0.12) / 0.66))
        let eased = travel * travel * (3 - 2 * travel)
        let routing = journey.status != .idle && !verifying
        let x = routing ? 0.38 + (target - 0.12 - 0.38) * eased : 0.38
        let y = routing ? 0.24 + 0.27 * eased - sin(eased * .pi) * 0.12 : 0.24
        let file = rect(x, y, 0.24, 0.24, size)
        image("ScanPaper", in: file, context: context)
        let symbol = verifying ? "checkmark.shield" : symbols[active ?? 0]
        var fileSymbol = context.resolve(Image(systemName: symbol))
        fileSymbol.shading = .color(Color(hex: 0x656C6E))
        context.draw(fileSymbol, in: CGRect(x: file.minX + file.width * 0.38, y: file.minY + file.height * 0.29,
                                           width: file.width * 0.23, height: file.height * 0.28))

        for index in centers.indices {
            let current = active == index && journey.status != .idle
            let read = journey.completedIDs.contains("scan.stage." + ids[index])
            let badge = rect(centers[index] - 0.068, compact ? 0.705 : 0.69, 0.136, compact ? 0.14 : 0.16, size)
            context.fill(Path(roundedRect: badge, cornerRadius: compact ? 3 : 5),
                         with: .color(Color(hex: current ? 0xF5EAD0 : read ? 0xD5D5CD : 0xF2F0E8)))
            context.stroke(Path(roundedRect: badge, cornerRadius: compact ? 3 : 5),
                           with: .color(Color(hex: current ? 0xAF8D4D : 0xBABBB4)), lineWidth: current ? 1.2 : 0.5)
            let icon = CGRect(x: badge.midX - badge.width * 0.16, y: badge.minY + badge.height * 0.15,
                              width: badge.width * 0.32, height: badge.height * (compact ? 0.65 : 0.42))
            var badgeSymbol = context.resolve(Image(systemName: symbols[index]))
            badgeSymbol.shading = .color(Color(hex: 0x525A5B))
            context.draw(badgeSymbol, in: icon)
            if !compact {
                context.draw(Text(L10n.t(labels[index])).font(.system(size: max(8, size.width * 0.023)))
                    .foregroundColor(Color(hex: 0x414747)), at: CGPoint(x: badge.midX, y: badge.minY + badge.height * 0.78))
            }
        }
    }

    private func disk(_ context: GraphicsContext, _ size: CGSize) {
        support(in: rect(0.1, 0.65, 0.43, 0.13, size), context: context)
        let drive = rect(-0.07, 0.25, 0.68, 0.72, size)
        image("ScanDiskDrive", in: drive, context: context)
        let phase = elapsed.truncatingRemainder(dividingBy: 3.3) / 3.3
        let travel = reduceMotion ? 0.3 : (1 - cos(phase * 2 * .pi)) / 2
        image("ScanPaper", in: rect(0.503 - travel * 0.012, 0.03 - travel * 0.08, 0.46, 0.46, size),
              rotation: -7 - travel * 3, context: context)
        image("ScanPaper", in: rect(0.535 + travel * 0.025, 0.06 - travel * 0.1, 0.46, 0.46, size),
              rotation: 3 + travel * 5, context: context)
        image("ScanDiskFolder", in: rect(0.42, 0.062, 0.64, 0.8, size), context: context)
        if journey.status == .running && !reduceMotion {
            var led = context
            led.opacity = 0.35 + travel * 0.65
            let point = CGPoint(x: drive.minX + drive.width * 0.71, y: drive.minY + drive.height * 0.63)
            led.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)),
                     with: .color(Color(hex: 0xD7C295)))
        }
    }
}
