import AppKit
import Foundation

// Asset-only runner: does not link AppDelegate, user preferences, scanners,
// cleanup/uninstall executors, pet stores or the live app's export scene.
@main struct AppIconAssetsMain {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw failure("usage: app-icon-assets REPOSITORY_ROOT")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let exports = root.appendingPathComponent("workspace/app-icon-exports", isDirectory: true)
        let assets = root.appendingPathComponent("app/MacDefier/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
        guard FileManager.default.fileExists(atPath: assets.appendingPathComponent("Contents.json").path) else {
            throw failure("AppIcon catalog missing")
        }
        let specs: [(String, Int)] = [
            ("icon_16_1x", 16), ("icon_16_2x", 32), ("icon_32_1x", 32), ("icon_32_2x", 64),
            ("icon_128_1x", 128), ("icon_128_2x", 256), ("icon_256_1x", 256),
            ("icon_256_2x", 512), ("icon_512_1x", 512), ("icon_512_2x", 1024)
        ]
        var count = 0
        for (tag, isPrimary) in [("v4b", true), ("v4", false)] {
            let masterURL = exports.appendingPathComponent("MacDefier-MrDefier-\(tag)-1024.png")
            guard let master = NSImage(contentsOf: masterURL),
                  let image = master.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw failure("Composition master missing: \(masterURL.path)")
            }
            let raw = NSBitmapImageRep(cgImage: image)
            // Never apply the inset twice. Full-bleed masters stay unchanged;
            // only icon variants and their matching previews are overwritten.
            guard image.width == 1024, image.height == 1024,
                  (raw.colorAt(x: 0, y: 0)?.alphaComponent ?? 0) > 0.99 else {
                throw failure("Expected an unmasked 1024px composition master")
            }
            for (name, edge) in specs {
                guard let icon = MacAppIconArtwork.render(master, edge: edge),
                      let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw failure("Icon rendering failed: \(name)")
                }
                let rep = NSBitmapImageRep(cgImage: cg)
                guard rep.pixelsWide == edge, rep.pixelsHigh == edge,
                      [(0, 0), (edge - 1, 0), (0, edge - 1), (edge - 1, edge - 1)]
                        .allSatisfy({ (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) == 0 }),
                      (rep.colorAt(x: edge / 2, y: 0)?.alphaComponent ?? 1) == 0,
                      (rep.colorAt(x: edge / 2, y: edge / 2)?.alphaComponent ?? 0) > 0.99,
                      let png = rep.representation(using: .png, properties: [:]) else {
                    throw failure("Invalid dimensions or alpha silhouette: \(name)")
                }
                let filename = name + (isPrimary ? "" : "-v4") + ".png"
                try png.write(to: exports.appendingPathComponent(filename), options: .atomic)
                if isPrimary { try png.write(to: assets.appendingPathComponent(filename), options: .atomic) }
                if [16, 32, 128].contains(edge) {
                    try png.write(to: exports.appendingPathComponent("final-\(tag)-\(edge).png"), options: .atomic)
                }
                print("PASS \(tag) \(filename) \(edge)x\(edge) corners=transparent center=opaque")
                count += 1
            }
        }
        print("APP_ICON_ASSETS_OK variants=\(count) artwork=unchanged-code-rendered-pet")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MacDefierIconAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
