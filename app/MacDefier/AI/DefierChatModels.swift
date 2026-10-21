// Mr. Defier avatar rendering used by the native chat UI.

import AppKit
import SwiftUI

enum DefierAvatar {
    /// Chat bubble avatar matching current pet skin.
    static func image(size: CGFloat, skin: PetSkin = PetSkinStore.current) -> NSImage {
        // Prefer packaged art if present
        if let asset = PetAssets.image(for: .idle, skin: skin) {
            let s = max(40, size)
            let out = NSImage(size: NSSize(width: s, height: s))
            out.lockFocus()
            NSColor.clear.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s)).fill()
            let aspect = min(s / asset.size.width, s / asset.size.height)
            let w = asset.size.width * aspect
            let h = asset.size.height * aspect
            asset.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h),
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1)
            out.unlockFocus()
            return out
        }

        return knightAvatar(size: size)
    }

    private static func knightAvatar(size: CGFloat) -> NSImage {
        let s = max(40, size)
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            // soft head
            let head = NSBezierPath(roundedRect: NSRect(x: s * 0.14, y: s * 0.32, width: s * 0.72, height: s * 0.58), xRadius: s * 0.32, yRadius: s * 0.32)
            let g = NSGradient(colors: [
                NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1),
                NSColor(calibratedRed: 0.78, green: 0.84, blue: 0.90, alpha: 1),
                NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.78, alpha: 1)
            ])
            g?.draw(in: head, angle: -45)

            // antenna
            NSColor(calibratedRed: 0.24, green: 0.61, blue: 1, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.42, y: s * 0.86, width: s * 0.16, height: s * 0.14)).fill()

            // visor
            let visor = NSBezierPath(roundedRect: NSRect(x: s * 0.26, y: s * 0.48, width: s * 0.48, height: s * 0.22), xRadius: s * 0.1, yRadius: s * 0.1)
            NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.16, alpha: 1).setFill()
            visor.fill()

            // blue eyes
            let eye = s * 0.13
            let ey = s * 0.52
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.30, y: ey, width: eye, height: eye)).fill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.55, y: ey, width: eye, height: eye)).fill()
            NSColor(calibratedRed: 0.23, green: 0.48, blue: 1, alpha: 1).setFill()
            let ir = eye * 0.62
            NSBezierPath(ovalIn: NSRect(x: s * 0.30 + (eye - ir) / 2, y: ey + (eye - ir) / 2, width: ir, height: ir)).fill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.55 + (eye - ir) / 2, y: ey + (eye - ir) / 2, width: ir, height: ir)).fill()

            // 面甲内不画外挂嘴（对齐干净 icon 脸）
            // body
            let body = NSBezierPath(roundedRect: NSRect(x: s * 0.22, y: s * 0.06, width: s * 0.56, height: s * 0.32), xRadius: s * 0.16, yRadius: s * 0.16)
            g?.draw(in: body, angle: -90)

            // shield + cross
            let sw = s * 0.2
            let sh = s * 0.24
            let sx = s * 0.5 - sw / 2
            let sy = s * 0.10
            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: sx + sw * 0.5, y: sy + sh))
            shield.curve(to: NSPoint(x: sx + sw, y: sy + sh * 0.2), controlPoint1: NSPoint(x: sx + sw * 0.85, y: sy + sh * 0.75), controlPoint2: NSPoint(x: sx + sw, y: sy + sh * 0.45))
            shield.curve(to: NSPoint(x: sx + sw * 0.5, y: sy), controlPoint1: NSPoint(x: sx + sw, y: sy + sh * 0.05), controlPoint2: NSPoint(x: sx + sw * 0.75, y: sy))
            shield.curve(to: NSPoint(x: sx, y: sy + sh * 0.2), controlPoint1: NSPoint(x: sx + sw * 0.25, y: sy), controlPoint2: NSPoint(x: sx, y: sy + sh * 0.05))
            shield.curve(to: NSPoint(x: sx + sw * 0.5, y: sy + sh), controlPoint1: NSPoint(x: sx, y: sy + sh * 0.45), controlPoint2: NSPoint(x: sx + sw * 0.15, y: sy + sh * 0.75))
            shield.close()
            NSGradient(colors: [
                NSColor(calibratedRed: 0.55, green: 0.77, blue: 1, alpha: 1),
                NSColor(calibratedRed: 0.36, green: 0.55, blue: 1, alpha: 1)
            ])?.draw(in: shield, angle: -90)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let crossV = NSBezierPath()
            crossV.move(to: NSPoint(x: s * 0.5, y: sy + sh * 0.22))
            crossV.line(to: NSPoint(x: s * 0.5, y: sy + sh * 0.72))
            crossV.lineWidth = max(1.2, s * 0.03)
            crossV.lineCapStyle = .round
            crossV.stroke()
            let crossH = NSBezierPath()
            crossH.move(to: NSPoint(x: s * 0.5 - sw * 0.22, y: sy + sh * 0.42))
            crossH.line(to: NSPoint(x: s * 0.5 + sw * 0.22, y: sy + sh * 0.42))
            crossH.lineWidth = max(1.2, s * 0.03)
            crossH.lineCapStyle = .round
            crossH.stroke()

            return true
        }
    }
}
