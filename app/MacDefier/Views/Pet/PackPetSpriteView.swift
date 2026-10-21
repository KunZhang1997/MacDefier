// Custom pack sprite playback — prefers pre-sliced frame files; safe crop fallback.

import AppKit
import Foundation
import ImageIO
import PetArchiveKit
import SwiftUI

// MARK: - Animation clip

struct PetAnimClip: Codable, Equatable {
    var frames: [Int]?
    var start: Int?
    var count: Int?
    var fps: Double?
    var loop: Bool?

    func resolvedFrames(totalCells: Int) -> [Int] {
        PetManifestSafety.resolvedFrames(
            frames: frames,
            start: start,
            count: count,
            totalCells: totalCells
        ) ?? [0]
    }

    var resolvedFPS: Double {
        min(8, max(2, fps ?? 5))
    }
}

// MARK: - Clip resolution

enum PetPackAnimation {
    static func clip(for mood: PetMood, manifest: PetPackManifest) -> (frames: [Int], fps: Double) {
        var cols = max(1, manifest.columns ?? 1)
        var rows = max(1, manifest.rows ?? 1)
        if PetManifestSafety.cellCount(columns: cols, rows: rows) == nil {
            cols = 1
            rows = 1
        }
        let total = PetManifestSafety.cellCount(columns: cols, rows: rows) ?? 1

        if let anims = manifest.animations, let clip = anims[mood.rawValue] {
            return (clip.resolvedFrames(totalCells: total), clip.resolvedFPS)
        }

        if let map = manifest.moodFrames,
           let one = map[mood.rawValue],
           one >= 0,
           one < total,
           total > 1 {
            let row = one / max(cols, 1)
            let rowStart = row * cols
            let rowEnd = min(total, rowStart + cols)
            if rowEnd - rowStart >= 2 {
                return (Array(rowStart..<rowEnd), fps(for: mood))
            }
            return ([min(one, total - 1)], 1)
        }

        let order: [PetMood] = [.idle, .talk, .alert, .happy, .sleep, .scan]
        if rows >= 6, let ri = order.firstIndex(of: mood) {
            let row = min(ri, rows - 1)
            let start = row * cols
            let end = min(total, start + cols)
            return (Array(start..<end), fps(for: mood))
        }

        if total >= 2 {
            switch mood {
            case .idle: return (Array(0..<min(cols, total)), fps(for: .idle))
            case .talk:
                if rows >= 2 { return (Array(cols..<min(total, cols * 2)), fps(for: .talk)) }
                return (Array(0..<min(total, 8)), fps(for: .talk))
            case .alert, .happy, .scan:
                if rows >= 3 {
                    let s = 2 * cols
                    return (Array(s..<min(total, s + cols)), fps(for: mood))
                }
                return (Array(0..<min(total, 8)), fps(for: mood))
            case .sleep:
                return ([max(0, (rows - 1) * cols)], 1)
            }
        }
        return ([0], 1)
    }

    private static func fps(for mood: PetMood) -> Double {
        switch mood {
        case .talk, .scan, .alert, .happy: return 6
        case .idle: return 4
        case .sleep: return 1
        }
    }
}

// MARK: - Frame cache

enum PetPackFrameCache {
    private static let lock = NSLock()
    private static var mem: [String: NSImage] = [:]
    private static var sheetCG: [String: CGImage] = [:]

    static func clear() {
        lock.lock(); mem.removeAll(); sheetCG.removeAll(); lock.unlock()
    }

    static func image(packId: String, packDir: URL, sheetURL: URL, index: Int, manifest: PetPackManifest) -> NSImage? {
        let key = "\(packId)#\(index)"
        lock.lock()
        if let hit = mem[key] { lock.unlock(); return hit }
        lock.unlock()

        // 1) Prefer pre-sliced frames/f_XXX.png (most reliable)
        let frameURL = packDir
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent(String(format: "f_%03d.png", index))
        if let fileImg = NSImage(contentsOf: frameURL) {
            fileImg.cacheMode = .always
            store(key, fileImg)
            return fileImg
        }

        // 2) Crop from sheet once
        guard let cg = sheet(sheetURL) else { return nil }
        let pw = cg.width, ph = cg.height
        guard pw > 0, ph > 0 else { return nil }

        var cols = max(1, manifest.columns ?? 1)
        var rows = max(1, manifest.rows ?? 1)
        if PetManifestSafety.cellCount(columns: cols, rows: rows) == nil {
            cols = 1
            rows = 1
        }
        if pw % cols != 0 || ph % rows != 0 {
            // Force exact grid by largest reasonable col that divides
            cols = 1; rows = 1
            for c in [10, 8, 6, 5, 4, 3, 2] where pw % c == 0 {
                for r in [11, 8, 6, 5, 4, 3, 2] where ph % r == 0 {
                    let cw = pw / c, ch = ph / r
                    if (64...512).contains(cw), (64...512).contains(ch) {
                        cols = c; rows = r
                        break
                    }
                }
                if cols > 1 { break }
            }
        }

        let fw = pw / cols
        let fh = ph / rows
        // Guard against multi-cell crops
        guard fw > 0, fh > 0, fw * 2 <= pw || cols == 1 else {
            // if fw would be huge, still crop top-left cell-sized square
            let side = min(pw, ph, 256)
            if let cut = cg.cropping(to: CGRect(x: 0, y: 0, width: side, height: side)) {
                let img = nsImage(cut)
                store(key, img)
                return img
            }
            return nil
        }

        if cols == 1 && rows == 1 {
            // single-image pack: still never show raw giant sheet in pet slot — center square
            let side = min(pw, ph)
            if let cut = cg.cropping(to: CGRect(x: (pw - side) / 2, y: (ph - side) / 2, width: side, height: side)) {
                let img = nsImage(cut)
                store(key, img)
                return img
            }
            return nil
        }

        let total = PetManifestSafety.cellCount(columns: cols, rows: rows) ?? 1
        let i = min(max(0, index), total - 1)
        let col = i % cols
        let row = i / cols
        let rect = CGRect(x: col * fw, y: row * fh, width: fw, height: fh)
        guard let cut = cg.cropping(to: rect) else { return nil }
        // Optional: also write frame file for next time
        writeFrameFile(cut, to: frameURL)
        let img = nsImage(cut)
        store(key, img)
        return img
    }

    private static func sheet(_ url: URL) -> CGImage? {
        let path = url.path
        lock.lock()
        if let s = sheetCG[path] { lock.unlock(); return s }
        lock.unlock()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }
        lock.lock(); sheetCG[path] = cg; lock.unlock()
        return cg
    }

    private static func nsImage(_ cg: CGImage) -> NSImage {
        // Do NOT use lockFocusFlipped — it inverted pets (坤小鸡头朝下).
        // NSImage(cgImage:size:) keeps CG top-left content upright in SwiftUI.
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        img.isTemplate = false
        img.cacheMode = .always
        return img
    }

    private static func writeFrameFile(_ cg: CGImage, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func store(_ key: String, _ img: NSImage) {
        lock.lock()
        if mem.count > 500 { mem.removeAll(keepingCapacity: true) }
        mem[key] = img
        lock.unlock()
    }
}

// MARK: - SwiftUI view

struct PackPetSpriteView: View {
    let pack: PetPack
    var mood: PetMood = .idle
    var size: CGFloat = 96
    var isActive: Bool = true

    @State private var images: [NSImage] = []
    @State private var tick: Int = 0
    @State private var fps: Double = 4

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.08))
                .frame(width: size * 0.36, height: size * 0.055)
                .offset(y: size * 0.42)

            if !images.isEmpty {
                // One image only; no drawingGroup (was causing composite glitches)
                Image(nsImage: images[tick % images.count])
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.92, height: size * 0.92)
                    .clipped()
            }
        }
        .frame(width: size, height: size * 1.14)
        .task(id: "\(pack.id)-\(mood.rawValue)-\(isActive)") {
            await reloadClipAsync()
            guard isActive, images.count > 1 else { return }
            let period = UInt64(max(0.18, 1.0 / max(fps, 1)) * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: period)
                if Task.isCancelled { break }
                // 仅在有图时推进，避免清空瞬间闪空白
                if !images.isEmpty {
                    tick = (tick + 1) % images.count
                }
            }
        }
    }

    /// Load off main-critical path; never assign empty array over existing frames (kills flicker).
    @MainActor
    private func reloadClipAsync() async {
        let clip = PetPackAnimation.clip(for: mood, manifest: pack.manifest)
        let indices = clip.frames.isEmpty ? [0] : clip.frames
        let nextFps = min(6, clip.fps)
        let packId = pack.id
        let packDir = pack.directory
        let sheetURL = pack.spritesheetURL
        let manifest = pack.manifest

        let imgs: [NSImage] = await Task.detached(priority: .userInitiated) {
            var out: [NSImage] = []
            out.reserveCapacity(indices.count)
            for i in indices {
                if let img = PetPackFrameCache.image(
                    packId: packId,
                    packDir: packDir,
                    sheetURL: sheetURL,
                    index: i,
                    manifest: manifest
                ) {
                    out.append(img)
                }
            }
            return out
        }.value

        guard !Task.isCancelled else { return }
        fps = nextFps
        if !imgs.isEmpty {
            // Cross-fade-free swap: keep showing last frame until new set is ready
            images = imgs
            tick = min(tick, imgs.count - 1)
        }
    }
}

extension PetPack {
    func image(atFrame index: Int) -> NSImage? {
        PetPackFrameCache.image(
            packId: id,
            packDir: directory,
            sheetURL: spritesheetURL,
            index: index,
            manifest: manifest
        )
    }

    var prefersPixelInterpolation: Bool {
        let fw = manifest.frameWidth ?? 0
        return fw > 0 && fw <= 160
    }
}
