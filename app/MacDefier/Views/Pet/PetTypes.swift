// Mr. Defier pet model — skins, moods, asset lookup, preference store.
// Window-internal mascot only (not a desktop Pad engine).

import AppKit
import Foundation
import SwiftUI

/// Six expression states. Status is face/antenna — never a permanent green online-dot.
enum PetMood: String, CaseIterable, Equatable, Identifiable {
    case idle
    case talk
    case alert
    case happy
    case sleep
    case scan

    var id: String { rawValue }

    var title: String {
        L10n.t("pet.mood.\(rawValue)")
    }

    var whenHint: String {
        L10n.t("pet.mood.\(rawValue).hint")
    }
}

/// Built-in skin: original procedural Mr. Defier only.
enum PetSkin: String, CaseIterable, Equatable, Identifiable {
    case knight

    var id: String { rawValue }

    var title: String { L10n.t("pet.skin.knight") }

    var subtitle: String { L10n.t("pet.skin.knight.sub") }

    /// File / catalog prefix for Resources/Pet
    var assetPrefix: String { "b" }
}

enum PetSkinStore {
    private static let key = "pet.skin"

    static let defaultSkin: PetSkin = .knight

    static var current: PetSkin {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? defaultSkin.rawValue
            if raw == "soft" || raw == "companion" { return .knight }
            return PetSkin(rawValue: raw) ?? defaultSkin
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    /// Binding-friendly AppStorage key
    static let appStorageKey = key
}

enum PetAssets {
    /// Prefer `pet_{a|b}_{mood}.png`, then legacy `pet_{mood}.png` / catalog names.
    static func image(for mood: PetMood, skin: PetSkin) -> NSImage? {
        let moodKey = mood.rawValue
        let prefix = skin.assetPrefix

        let catalogNames = [
            "Pet_\(prefix)_\(moodKey)",
            "Pet\(moodKey.capitalized)",
            "pet_\(prefix)_\(moodKey)",
            "pet_\(moodKey)"
        ]
        let fileNames = [
            "pet_\(prefix)_\(moodKey)",
            "pet_\(moodKey)",
            "Pet\(moodKey.capitalized)"
        ]

        for name in catalogNames {
            if let img = NSImage(named: name) { return img }
        }
        for name in fileNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) { return img }
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Pet"),
               let img = NSImage(contentsOf: url) { return img }
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Resources/Pet"),
               let img = NSImage(contentsOf: url) { return img }
        }

        // Fall back to idle art of same skin, then any idle
        if mood != .idle {
            return image(for: .idle, skin: skin)
        }
        return nil
    }
}

/// Pure geometry; unit checked without a WindowServer, filesystem or model service.
enum PetOverlayGeometry {
    static func clamp(_ offset: CGSize, window: CGSize, size: CGSize, margin: CGFloat) -> CGSize {
        let x = max(0, window.width - size.width - margin * 2)
        let y = max(0, window.height - size.height - margin * 2)
        return CGSize(width: max(-x, min(0, offset.width)),
                      height: max(-y, min(0, offset.height)))
    }

    static func petFrame(offset: CGSize, window: CGSize, size: CGSize, margin: CGFloat) -> CGRect {
        let position = clamp(offset, window: window, size: size, margin: margin)
        return CGRect(x: window.width - margin - size.width + position.width,
                      y: window.height - margin - size.height + position.height,
                      width: size.width, height: size.height)
    }

    static func popupFrame(near pet: CGRect, window: CGSize, preferred: CGSize, margin: CGFloat) -> CGRect {
        let w = min(preferred.width, max(1, window.width - margin * 2))
        let h = min(preferred.height, max(1, window.height - margin * 2))
        let gap: CGFloat = 10
        func bounded(_ x: CGFloat, _ y: CGFloat, width: CGFloat = w) -> CGRect {
            CGRect(x: max(margin, min(window.width - margin - width, x)),
                   y: max(margin, min(window.height - margin - h, y)),
                   width: width, height: h)
        }
        if pet.minY - gap - h >= margin { return bounded(pet.maxX - w, pet.minY - gap - h) }
        if pet.maxY + gap + h <= window.height - margin { return bounded(pet.maxX - w, pet.maxY + gap) }
        let left = pet.minX - gap - margin
        let right = window.width - margin - pet.maxX - gap
        if left >= min(280, w) {
            let width = min(w, left)
            return bounded(pet.minX - gap - width, pet.midY - h / 2, width: width)
        }
        if right >= min(280, w) { return bounded(pet.maxX + gap, pet.midY - h / 2, width: min(w, right)) }
        return bounded(pet.maxX - w, pet.minY - gap - h)
    }
}
