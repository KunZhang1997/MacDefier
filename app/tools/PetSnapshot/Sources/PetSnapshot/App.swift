import AppKit
import SwiftUI

// Renders the built-in knight pet (no custom pack) at every mood to PNGs.
// Usage: swift run -c release PetSnapshot [outDir]

@main
struct PetSnapshotMain {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        let outDir = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath + "/out"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let size: CGFloat = 160
        let scale: CGFloat = 3

        // 1) Per-mood singles (light window bg)
        for mood in PetMood.allCases {
            let view = petCell(mood: mood, size: size, bg: Color(hex: 0xECECEC), label: nil)
            save(view: view, scale: scale, to: "\(outDir)/single_\(mood.rawValue).png")
        }

        // 2) Contact sheet: all moods in a grid, light + dark rows
        let sheet = VStack(spacing: 18) {
            HStack(spacing: 10) {
                ForEach(PetMood.allCases) { mood in
                    petCell(mood: mood, size: 120, bg: Color(hex: 0xECECEC), label: mood.rawValue)
                }
            }
            HStack(spacing: 10) {
                ForEach(PetMood.allCases) { mood in
                    petCell(mood: mood, size: 120, bg: Color(hex: 0x2B2B30), label: mood.rawValue, dark: true)
                }
            }
        }
        .padding(20)
        .background(Color(hex: 0x808088))
        save(view: sheet, scale: 2, to: "\(outDir)/sheet_all.png")

        // 3) Size strip: real in-app sizes for the idle pet
        let sizes: [CGFloat] = [28, 36, 64, 96]
        let strip = HStack(alignment: .bottom, spacing: 16) {
            ForEach(sizes, id: \.self) { s in
                VStack(spacing: 4) {
                    DefierPetView(
                        mood: .idle,
                        skin: .knight,
                        size: s,
                        showsOnlineDot: false,
                        tracksLook: false,
                        preferCustomPack: false,
                        dragMotion: .init(),
                        onTap: {}
                    )
                    Text("\(Int(s))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.black.opacity(0.6))
                }
            }
        }
        .padding(16)
        .background(Color(hex: 0xECECEC))
        save(view: strip, scale: 4, to: "\(outDir)/sizes.png")

        print("done → \(outDir)")
    }

    static func petCell(mood: PetMood, size: CGFloat, bg: Color, label: String?, dark: Bool = false) -> some View {
        VStack(spacing: 4) {
            DefierPetView(
                mood: mood,
                skin: .knight,
                size: size,
                showsOnlineDot: false,
                tracksLook: false,
                preferCustomPack: false,
                dragMotion: .init(),
                onTap: {}
            )
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(dark ? Color.white.opacity(0.8) : Color.black.opacity(0.7))
            }
        }
        .padding(8)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @MainActor
    static func save<V: View>(view: V, scale: CGFloat, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else {
            print("render failed: \(path)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("png encode failed: \(path)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("write failed: \(path) \(error)")
        }
    }
}
