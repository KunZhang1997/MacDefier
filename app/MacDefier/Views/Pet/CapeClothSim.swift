// Cape secondary motion for a small icon pet.
//
// Coordinate conventions (must stay consistent with DefierCapeView draw):
//   +hemTip  → hem shifts RIGHT in the path
//   +angleDeg → SwiftUI clockwise rotation → hem swings LEFT on screen
//
// Trail rule (drag left → hem should appear to the RIGHT):
//   body dx < 0 (left) → hemTip > 0, angleDeg < 0
//   ⇒ hemVel −= dx * k,  angVel += dx * k

import Foundation
import CoreGraphics

struct CapeClothSnapshot: Equatable {
    /// Degrees about neck (±12°).
    var angleDeg: CGFloat = 0
    /// Hem tip lag (−1…1). + = path shifts hem right.
    var hemTip: CGFloat = 0
    /// Wind modulator for idle wave (−1…1).
    var breeze: CGFloat = 0
    var isDragging: Bool = false
    var energy: CGFloat = 0
}

@MainActor
final class CapeClothSim {
    private var lastTime: TimeInterval?
    private var wasDragging = false
    private var lastTX: CGFloat = 0
    private var lastTY: CGFloat = 0

    private var angle: CGFloat = 0
    private var angVel: CGFloat = 0
    private var hemTip: CGFloat = 0
    private var hemVel: CGFloat = 0
    private var energy: CGFloat = 0
    private var phase: Double = 0
    private var phase2: Double = 0

    private let maxAngle: CGFloat = 12
    private let maxHem: CGFloat = 0.55
    private let spring: CGFloat = 70
    private let damp: CGFloat = 9
    private let kickAngle: CGFloat = 3.4
    private let kickHem: CGFloat = 0.030

    func reset() {
        lastTime = nil
        wasDragging = false
        lastTX = 0
        lastTY = 0
        angle = 0
        angVel = 0
        hemTip = 0
        hemVel = 0
        energy = 0
        phase = 0
        phase2 = 0
    }

    @discardableResult
    func tick(
        now: TimeInterval,
        capeW: CGFloat,
        capeH: CGFloat,
        body: PetDragMotion,
        sleep: Bool
    ) -> CapeClothSnapshot {
        _ = capeW
        _ = capeH
        _ = now

        let dt: CGFloat
        if let t0 = lastTime {
            dt = CGFloat(min(1.0 / 20.0, max(1.0 / 90.0, now - t0)))
        } else {
            dt = 1.0 / 30.0
        }
        lastTime = now

        let dragging = body.isActive
        var stepMag: CGFloat = 0

        // —— Drag: trail behind body ——
        if dragging {
            let tx = body.translation.width
            let ty = body.translation.height
            if wasDragging {
                let dx = tx - lastTX
                let dy = ty - lastTY
                stepMag = hypot(dx, dy)
                // See file header for sign reasoning (trail left→hem right)
                angVel += dx * kickAngle
                angVel += dy * kickAngle * 0.22
                hemVel -= dx * kickHem
                hemVel -= dy * kickHem * 0.18
            }
            lastTX = tx
            lastTY = ty
            wasDragging = true
        } else {
            wasDragging = false
        }

        // —— Spring home ——
        let springScale: CGFloat = dragging ? 0.4 : 1.0
        angVel += (-angle * spring * springScale) * dt
        angVel *= exp(-damp * dt)
        angVel = max(-90, min(90, angVel))
        angle += angVel * dt
        angle = max(-maxAngle, min(maxAngle, angle))

        hemVel += (-hemTip * spring * 1.1 * springScale) * dt
        hemVel *= exp(-damp * 1.05 * dt)
        hemVel = max(-2.5, min(2.5, hemVel))
        hemTip += hemVel * dt
        hemTip = max(-maxHem, min(maxHem, hemTip))

        let targetE = min(1, stepMag / 10 + abs(angle) / maxAngle * 0.5 + abs(hemTip) / maxHem * 0.35)
        energy += (targetE - energy) * (1 - exp(-(dragging ? 12 : 5) * dt))

        // —— Idle wind: always on when not dragging ——
        let windSpeed: Double = sleep ? 1.15 : 2.8
        phase += Double(dt) * windSpeed
        phase2 += Double(dt) * windSpeed * 1.65
        let w1 = CGFloat(sin(phase))
        let w2 = CGFloat(sin(phase2 + 0.7))
        let w3 = CGFloat(sin(phase * 0.5 + 1.1))
        let breeze = w1 * 0.55 + w2 * 0.30 + w3 * 0.15

        if !dragging {
            // Continuous wind force so cape keeps swaying at rest
            let amp: CGFloat = sleep ? 0.45 : 1.0
            hemVel += breeze * (sleep ? 1.2 : 3.2) * amp * dt
            angVel += breeze * (sleep ? 8 : 22) * amp * dt
            hemVel += w2 * (sleep ? 0.35 : 1.0) * amp * dt
        }

        let breezeOut = dragging ? breeze * 0.1 : breeze * (sleep ? 0.5 : 1.0)

        return CapeClothSnapshot(
            angleDeg: angle,
            hemTip: hemTip,
            breeze: breezeOut,
            isDragging: dragging,
            energy: energy
        )
    }
}
