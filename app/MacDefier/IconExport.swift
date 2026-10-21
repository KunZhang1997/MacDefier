// Export App Icon using the real DefierPetView (never redraw Mr. Defier).
// Usage: open MacDefier.app --args --export-app-icon [outputDir]
//
// 同目录两版构图（不另开文件夹）：
// - v4 / face：头肩近景（当前 AppIcon）
// - v4b / body：头略小，露出胸盾十字 + 金领 + 披风（安全感）

import AppKit
import SwiftUI

enum IconExport {
    /// 一套裁切 + 落幅参数。
    private struct Composition {
        var tag: String
        var cropX: CGFloat
        var cropY: CGFloat
        var cropW: CGFloat
        var cropH: CGFloat
        var drawWidthFrac: CGFloat
        var bottomBleedFrac: CGFloat
        var minTopAirFrac: CGFloat
        var maxWidthFrac: CGFloat

        /// 现用 AppIcon：大头近景。
        /// cropY 从天线上方透明区起（render 已 topPad）；minTopAir 保证落幅不切球。
        static let face = Composition(
            tag: "v4",
            cropX: 0.05, cropY: 0.02, cropW: 0.90, cropH: 0.58,
            drawWidthFrac: 0.96,
            bottomBleedFrac: 0.08,
            minTopAirFrac: 0.07,
            maxWidthFrac: 1.20
        )

        /// 定稿：头略小、露胸盾/披风；略放大；底出血把身子横切灰边推到画外。
        static let body = Composition(
            tag: "v4b",
            cropX: 0.035, cropY: 0.02, cropW: 0.93, cropH: 0.80,
            drawWidthFrac: 0.97,
            bottomBleedFrac: 0.22,
            minTopAirFrac: 0.06,
            maxWidthFrac: 1.18
        )
    }

    private static let petPointSize: CGFloat = 900
    private static let renderScale: CGFloat = 2

    @MainActor
    static func exportIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--export-app-icon") else { return false }

        let outDir: URL
        if args.count > idx + 1, !args[idx + 1].hasPrefix("-") {
            outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        } else {
            outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("app-icon-exports", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        PetSkinStore.current = .knight
        PetPackStore.shared.selectBuiltIn()

        // 一次渲染 pet，两套裁切 → 同目录并排，不另建路径
        guard let cleaned = renderPetCleaned() else {
            fputs("IconExport: pet render failed\n", stderr)
            return true
        }

        let face = Composition.face
        let body = Composition.body
        guard let faceMaster = compose(cleaned: cleaned, size: 1024, comp: face),
              let bodyMaster = compose(cleaned: cleaned, size: 1024, comp: body) else {
            fputs("IconExport: compose failed\n", stderr)
            return true
        }

        // 通用名 + 并排两版（同目录）
        savePNG(bodyMaster, to: outDir.appendingPathComponent("MacDefier-MrDefier-1024.png"))
        savePNG(faceMaster, to: outDir.appendingPathComponent("MacDefier-MrDefier-v4-1024.png"))
        savePNG(bodyMaster, to: outDir.appendingPathComponent("MacDefier-MrDefier-v4b-1024.png"))
        for edge in [128, 32, 16] {
            if let bodyIcon = MacAppIconArtwork.render(bodyMaster, edge: edge),
               let faceIcon = MacAppIconArtwork.render(faceMaster, edge: edge) {
                savePNG(bodyIcon, to: outDir.appendingPathComponent("final-v4b-\(edge).png"))
                savePNG(faceIcon, to: outDir.appendingPathComponent("final-v4-\(edge).png"))
            }
        }

        // AppIcon 写入 v4b（用户选定）
        let assetDir = resolveAppIconsetDir()
        let specs: [(String, Int)] = [
            ("icon_16_1x.png", 16),
            ("icon_16_2x.png", 32),
            ("icon_32_1x.png", 32),
            ("icon_32_2x.png", 64),
            ("icon_128_1x.png", 128),
            ("icon_128_2x.png", 256),
            ("icon_256_1x.png", 256),
            ("icon_256_2x.png", 512),
            ("icon_512_1x.png", 512),
            ("icon_512_2x.png", 1024)
        ]
        for (name, px) in specs {
            guard let img = MacAppIconArtwork.render(bodyMaster, edge: px) else { continue }
            savePNG(img, to: outDir.appendingPathComponent(name))
            if let assetDir {
                savePNG(img, to: assetDir.appendingPathComponent(name))
            }
        }
        // face 旁路文件名加 -v4，便于回看
        for (name, px) in specs {
            let base = name.replacingOccurrences(of: ".png", with: "-v4.png")
            if let img = MacAppIconArtwork.render(faceMaster, edge: px) {
                savePNG(img, to: outDir.appendingPathComponent(base))
            }
        }

        fputs("IconExport: OK primary=v4b (assets) face=v4 kept \(outDir.path)\n", stderr)
        if let assetDir { fputs("IconExport: assets(v4b) \(assetDir.path)\n", stderr) }
        return true
    }

    /// 高分辨率 pet 渲染一次，去黄/黑底。
    /// 顶部必须留空：天线小球若贴 frame 顶边，裁切后会变成「半个球」。
    @MainActor
    private static func renderPetCleaned() -> CGImage? {
        let petSize = petPointSize
        let topPad = petSize * 0.14
        let frameW = petSize * 1.18
        let contentH = petSize * 1.40
        let frameH = contentH + topPad

        let petView = DefierPetView(
            mood: .idle,
            skin: .knight,
            size: petSize,
            showsOnlineDot: false,
            tracksLook: false,
            preferCustomPack: false,
            onTap: {}
        )
        .frame(width: frameW, height: contentH, alignment: .top)
        .padding(.top, topPad)
        .frame(width: frameW, height: frameH, alignment: .top)
        .background(Color.clear)

        let renderer = ImageRenderer(content: petView)
        renderer.scale = renderScale
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(width: frameW, height: frameH)

        RunLoop.current.run(until: Date().addingTimeInterval(0.12))

        guard let petCG = renderer.cgImage else { return nil }
        return stripSolidBackdrop(from: petCG)
    }

    /// Full-bleed composition master; legacy icon variants receive a transparent
    /// continuous-corner outline in MacAppIconArtwork before entering AppIcon.
    private static func compose(cleaned: CGImage, size: CGFloat, comp: Composition) -> NSImage? {
        let fullW = CGFloat(cleaned.width)
        let fullH = CGFloat(cleaned.height)
        let cropX = fullW * comp.cropX
        let cropY = fullH * comp.cropY
        let cropW = fullW * comp.cropW
        let cropH = fullH * comp.cropH
        var cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard var halfBody = cleaned.cropping(to: cropRect) else { return nil }
        if looksMostlyCape(halfBody) {
            cropRect = CGRect(x: cropX, y: fullH - cropH, width: cropW, height: cropH)
            if let alt = cleaned.cropping(to: cropRect) {
                halfBody = alt
            }
        }

        let px = Int(size)
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
        ) else { return nil }
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        guard let ng = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ng
        ng.imageInterpolation = .high
        let ctx = ng.cgContext

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.setFillColor(NSColor(calibratedRed: 0, green: 0x7A / 255, blue: 1, alpha: 1).cgColor)
        ctx.fill(rect)

        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [
            NSColor(calibratedRed: 0x4A / 255, green: 0xA3 / 255, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0, green: 0x7A / 255, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0, green: 0x55 / 255, blue: 0xD4 / 255, alpha: 1).cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: 0, y: size),
                end: CGPoint(x: size, y: 0),
                options: []
            )
        }
        if let gloss = CGGradient(
            colorsSpace: space,
            colors: [
                NSColor.white.withAlphaComponent(0.28).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(
                gloss,
                startCenter: CGPoint(x: size * 0.3, y: size * 0.75),
                startRadius: 0,
                endCenter: CGPoint(x: size * 0.3, y: size * 0.75),
                endRadius: size * 0.55,
                options: []
            )
        }

        let aspect = CGFloat(halfBody.width) / max(1, CGFloat(halfBody.height))
        let topAir = size * comp.minTopAirFrac
        let bleed = size * comp.bottomBleedFrac
        var drawH = size - topAir + bleed
        var drawW = drawH * aspect
        let maxW = size * comp.maxWidthFrac
        if drawW > maxW {
            drawW = maxW
            drawH = drawW / aspect
        }
        let minW = size * comp.drawWidthFrac
        if drawW < minW {
            drawW = minW
            drawH = drawW / aspect
        }
        let dx = (size - drawW) / 2
        var dy = -bleed
        let topY = dy + drawH
        if topY >= size - topAir {
            dy = size - topAir - drawH
        }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setBlendMode(.normal)
        ctx.draw(halfBody, in: CGRect(x: dx, y: dy, width: drawW, height: drawH))
        ctx.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        // 细黑/灰裁切线：只清最底 1～2 行的暗边，避免整条蓝带
        scrubBottomCropHairline(rep: rep, edge: px)

        let out = NSImage(size: NSSize(width: size, height: size))
        out.addRepresentation(rep)
        return out
    }

    /// 最底 2 行：暗裁切毛边 → 侧边蓝；红披风保留。
    private static func scrubBottomCropHairline(rep: NSBitmapImageRep, edge: Int) {
        guard edge > 8, let data = rep.bitmapData else { return }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let spp = max(1, rep.bitsPerPixel / 8)
        let rowBytes = rep.bytesPerRow
        let band = 3

        for y in (h - band)..<h {
            let sampleX = max(2, w / 14)
            let sOff = y * rowBytes + sampleX * spp
            let br = data[sOff], bg = data[sOff + 1], bb = data[sOff + 2]

            for x in 0..<w {
                let off = y * rowBytes + x * spp
                let r = Int(data[off]), g = Int(data[off + 1]), b = Int(data[off + 2])
                if r > g + 30 && r > b + 15 { continue }
                let mx = max(r, max(g, b))
                let mn = min(r, min(g, b))
                // 暗毛边或发灰横切线
                let darkEdge = mx < 140 && (mx - mn) < 35
                let grayEdge = mx > 90 && mx < 200 && (mx - mn) < 22
                guard darkEdge || grayEdge else { continue }
                data[off] = br
                data[off + 1] = bg
                data[off + 2] = bb
            }
        }
    }

    /// 裁完若大片深红，多半裁到披风下半，不是半身脸
    private static func looksMostlyCape(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return false }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var red = 0, white = 0, n = 0
        let step = max(1, (w * h) / 800)
        for i in stride(from: 0, to: data.count, by: 4 * step) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2]), a = Int(data[i + 3])
            guard a > 180 else { continue }
            n += 1
            if r > g + 30 && r > b + 20 { red += 1 }
            if r > 200 && g > 200 && b > 200 { white += 1 }
        }
        guard n > 20 else { return false }
        return Double(red) / Double(n) > 0.45 && Double(white) / Double(n) < 0.12
    }

    /// Remove solid yellow/black fill ImageRenderer sometimes bakes behind the pet.
    private static func stripSolidBackdrop(from image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var data = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        for i in stride(from: 0, to: data.count, by: 4) {
            let r = data[i], g = data[i + 1], b = data[i + 2], a = data[i + 3]
            // pure / near yellow #FFCC00 family
            let isYellow = r > 240 && g > 180 && g < 230 && b < 50 && a > 200
            // solid black backdrop
            let isBlack = r < 8 && g < 8 && b < 8 && a > 200
            if isYellow || isBlack {
                data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 0
            }
        }
        return ctx.makeImage()
    }

    /// Exact pixel resize (no Retina 2× lockFocus inflation).
    private static func resize(_ image: NSImage, to edge: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: edge,
            pixelsHigh: edge,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return image
        }
        rep.size = NSSize(width: edge, height: edge)
        NSGraphicsContext.saveGraphicsState()
        if let ng = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ng
            ng.imageInterpolation = .high
            let srcSize = image.size
            image.draw(
                in: NSRect(x: 0, y: 0, width: edge, height: edge),
                from: NSRect(origin: .zero, size: srcSize),
                operation: .sourceOver,
                fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: edge, height: edge))
        out.addRepresentation(rep)
        return out
    }

    private static func savePNG(_ image: AppKit.NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func resolveAppIconsetDir() -> URL? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("MacDefier/Assets.xcassets/AppIcon.appiconset"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("app/MacDefier/Assets.xcassets/AppIcon.appiconset")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
