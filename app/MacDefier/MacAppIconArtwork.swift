import AppKit
import SwiftUI

/// Legacy macOS AppIcon PNGs must carry their own silhouette. Newer system
/// masking is not available on every supported OS (including macOS 15).
/// This is presentation of the existing code-rendered pet, not a new drawing.
enum MacAppIconArtwork {
    static func render(_ artwork: NSImage, edge: Int) -> NSImage? {
        guard edge > 0, edge <= 8192,
              let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: edge, height: edge,
                bitsPerComponent: 8, bytesPerRow: edge * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: edge, height: edge)
        context.clear(canvas)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        // Optical breathing room keeps this tile comparable to legacy Mac
        // application icons rather than oversized in Launchpad and Finder.
        let tile = canvas.insetBy(dx: canvas.width * 0.08, dy: canvas.height * 0.08)
        let outline = RoundedRectangle(cornerRadius: tile.width * 0.223, style: .continuous)
            .path(in: tile).cgPath
        context.addPath(outline)
        context.clip()
        context.draw(source, in: tile)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: edge, height: edge))
    }
}
