// AppKit drag host — blocks window background drag (fullSizeContentView).
// Content stays in pure SwiftUI; only a transparent hit layer is AppKit.
// (Re-hosting DefierPetView inside NSHostingView on every drag event freezes the UI.)

import AppKit
import SwiftUI

/// Drag translation + velocity in SwiftUI coords (+x right, +y down).
struct PetDragMotion: Equatable {
    var translation: CGSize = .zero
    /// Points per second (approx.); used for cloth lag.
    var velocity: CGSize = .zero
    var isActive: Bool = false
}

/// Wraps pet content: SwiftUI draws the pet; a clear AppKit layer handles drag/click.
struct PetDragContainer<Content: View>: View {
    var onDragChanged: (PetDragMotion) -> Void
    var onDragEnded: (PetDragMotion) -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void
    var accessibilityLabel: String? = nil
    var onKeyboardMove: ((CGSize) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .overlay {
                PetDragHitView(
                    onDragChanged: onDragChanged,
                    onDragEnded: onDragEnded,
                    onClick: onClick,
                    onDoubleClick: onDoubleClick,
                    accessibilityLabel: accessibilityLabel,
                    onKeyboardMove: onKeyboardMove
                )
            }
    }
}

/// Transparent hit target only — never hosts SwiftUI pet content.
private struct PetDragHitView: NSViewRepresentable {
    var onDragChanged: (PetDragMotion) -> Void
    var onDragEnded: (PetDragMotion) -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void
    var accessibilityLabel: String?
    var onKeyboardMove: ((CGSize) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PetDragHitNSView {
        let v = PetDragHitNSView()
        v.coordinator = context.coordinator
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onClick = onClick
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onKeyboardMove = onKeyboardMove
        v.setAccessibilityElement(accessibilityLabel != nil)
        if let accessibilityLabel {
            v.setAccessibilityRole(.button)
            v.setAccessibilityLabel(accessibilityLabel)
            v.setAccessibilityHelp(L10n.t("pet.help_drag"))
        }
        return v
    }

    func updateNSView(_ nsView: PetDragHitNSView, context: Context) {
        // Callbacks only — do not rebuild any view tree here.
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onClick = onClick
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onKeyboardMove = onKeyboardMove
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var onDragChanged: ((PetDragMotion) -> Void)?
        var onDragEnded: ((PetDragMotion) -> Void)?
        var onClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onKeyboardMove: ((CGSize) -> Void)?
        var clickWorkItem: DispatchWorkItem?
    }

    final class PetDragHitNSView: NSView {
        var coordinator: Coordinator?

        private var mouseDownWindowPoint: CGPoint?
        private var isDragging = false
        private var lastSampleTime: TimeInterval = 0
        private var lastSamplePoint: CGPoint = .zero
        private var smoothedVelocity: CGSize = .zero

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Fill bounds for hit testing even though we draw nothing.
            guard !isHidden else { return nil }
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func accessibilityPerformPress() -> Bool {
            guard let action = coordinator?.onClick else { return false }
            action()
            return true
        }

        override func keyDown(with event: NSEvent) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 30 : 10
            let delta: CGSize?
            switch event.keyCode {
            case 123: delta = CGSize(width: -step, height: 0)
            case 124: delta = CGSize(width: step, height: 0)
            case 125: delta = CGSize(width: 0, height: step)
            case 126: delta = CGSize(width: 0, height: -step)
            case 36, 49: coordinator?.onClick?(); return
            case 115: coordinator?.onDoubleClick?(); return
            default: super.keyDown(with: event); return
            }
            if let delta { coordinator?.onKeyboardMove?(delta) }
        }

        override func mouseDown(with event: NSEvent) {
            coordinator?.clickWorkItem?.cancel()
            window?.makeFirstResponder(self)
            mouseDownWindowPoint = event.locationInWindow
            isDragging = false
            lastSampleTime = ProcessInfo.processInfo.systemUptime
            lastSamplePoint = event.locationInWindow
            smoothedVelocity = .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownWindowPoint else { return }
            let p = event.locationInWindow
            let dx = p.x - start.x
            let dyCocoa = p.y - start.y
            if !isDragging {
                if hypot(dx, dyCocoa) < 5 { return }
                isDragging = true
                coordinator?.clickWorkItem?.cancel()
            }

            let now = ProcessInfo.processInfo.systemUptime
            let dt = max(1.0 / 120.0, min(now - lastSampleTime, 0.05))
            let stepX = p.x - lastSamplePoint.x
            let stepY = -(p.y - lastSamplePoint.y)
            let instant = CGSize(width: stepX / dt, height: stepY / dt)
            smoothedVelocity = CGSize(
                width: smoothedVelocity.width * 0.55 + instant.width * 0.45,
                height: smoothedVelocity.height * 0.55 + instant.height * 0.45
            )
            lastSampleTime = now
            lastSamplePoint = p

            coordinator?.onDragChanged?(
                PetDragMotion(
                    translation: CGSize(width: dx, height: -dyCocoa),
                    velocity: smoothedVelocity,
                    isActive: true
                )
            )
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownWindowPoint = nil
            }
            guard let start = mouseDownWindowPoint else {
                isDragging = false
                smoothedVelocity = .zero
                return
            }
            let p = event.locationInWindow
            let dx = p.x - start.x
            let dyCocoa = p.y - start.y
            let dist = hypot(dx, dyCocoa)
            let vel = smoothedVelocity
            smoothedVelocity = .zero

            if isDragging || dist >= 5 {
                isDragging = false
                coordinator?.onDragEnded?(
                    PetDragMotion(
                        translation: CGSize(width: dx, height: -dyCocoa),
                        velocity: vel,
                        isActive: false
                    )
                )
                return
            }
            isDragging = false

            if event.clickCount >= 2 {
                coordinator?.clickWorkItem?.cancel()
                coordinator?.onDoubleClick?()
                return
            }

            coordinator?.clickWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.coordinator?.onClick?()
            }
            coordinator?.clickWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }
}
