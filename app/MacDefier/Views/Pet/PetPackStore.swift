// Custom pet packs — import zip (pet.json + spritesheet), store under Application Support.
// Built-in soft/knight remain fallbacks when no pack is active.

import AppKit
import Foundation
import ImageIO
import PetArchiveKit
import UniformTypeIdentifiers

// MARK: - Manifest (on-disk pet.json)

struct PetPackManifest: Codable, Equatable {
    var id: String
    var displayName: String
    var description: String?
    var spritesheetPath: String
    var spriteVersionNumber: Int?
    /// Optional grid. If missing, importer may infer from image size.
    var columns: Int?
    var rows: Int?
    /// Mood → single frame index (row-major). Used when animations missing.
    var moodFrames: [String: Int]?
    /// Optional per-frame pixel size.
    var frameWidth: Int?
    var frameHeight: Int?
    /// Per-mood clip sequences (pack's own trajectory). Key = idle/talk/…
    var animations: [String: PetAnimClip]?

    enum CodingKeys: String, CodingKey {
        case id, displayName, description, spritesheetPath, spriteVersionNumber
        case columns, rows, moodFrames, frameWidth, frameHeight, animations
    }
}

// MARK: - Runtime pack

struct PetPack: Identifiable, Equatable {
    var id: String { manifest.id }
    var manifest: PetPackManifest
    var directory: URL
    var spritesheetURL: URL

    var displayName: String { manifest.displayName }

    func frameImage(mood: PetMood) -> NSImage? {
        let idx = frameIndex(for: mood)
        return PetPackRenderer.frame(at: spritesheetURL, index: idx, manifest: manifest)
    }

    func previewImage() -> NSImage? {
        frameImage(mood: .idle)
    }

    private func frameIndex(for mood: PetMood) -> Int {
        if let map = manifest.moodFrames, let i = map[mood.rawValue] { return max(0, i) }
        let order: [PetMood] = [.idle, .talk, .alert, .happy, .sleep, .scan]
        if let i = order.firstIndex(of: mood) { return i }
        return 0
    }
}

// MARK: - Sheet cropping (thin wrapper → cache)

enum PetPackRenderer {
    static func frame(at url: URL, index: Int, manifest: PetPackManifest) -> NSImage? {
        let packDir = url.deletingLastPathComponent()
        let packId = packDir.lastPathComponent
        return PetPackFrameCache.image(
            packId: packId,
            packDir: packDir,
            sheetURL: url,
            index: index,
            manifest: manifest
        )
    }
}

// MARK: - Store

@MainActor
final class PetPackStore: ObservableObject {
    static let shared = PetPackStore()

    @Published private(set) var packs: [PetPack] = []
    /// nil = use built-in PetSkin (soft/knight)
    @Published var activePackId: String? {
        didSet { UserDefaults.standard.set(activePackId, forKey: Keys.active) }
    }

    private enum Keys {
        static let active = "pet.pack.activeId"
    }

    private enum ImportLimit {
        static let archiveBytes = PetArchiveExtractor.Limit.archiveBytes
        static let entryCount = PetArchiveExtractor.Limit.entryCount
        static let expandedBytes = PetArchiveExtractor.Limit.expandedBytes
        static let imagePixels = PetArchiveExtractor.Limit.imagePixels
        static let processTimeout = PetArchiveExtractor.Limit.timeout
    }

    private var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if DEBUG
        return base.appendingPathComponent("MacDefier-Dev/PetPacks", isDirectory: true)
        #else
        return base.appendingPathComponent("MacDefier/PetPacks", isDirectory: true)
        #endif
    }

    private init() {
        activePackId = UserDefaults.standard.string(forKey: Keys.active)
        reload()
    }

    var activePack: PetPack? {
        guard let id = activePackId else { return nil }
        return packs.first { $0.id == id }
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var list: [PetPack] = []
        guard let dirs = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            packs = []
            return
        }
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let jsonURL = dir.appendingPathComponent("pet.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  var manifest = try? JSONDecoder().decode(PetPackManifest.self, from: data) else { continue }
            let sheetName = manifest.spritesheetPath.isEmpty ? "spritesheet.png" : manifest.spritesheetPath
            let sheetURL = dir.appendingPathComponent(sheetName)
            guard fm.fileExists(atPath: sheetURL.path) else { continue }

            // Prefer author grid. If missing, try conservative inference (near-square cells ≥160px).
            // Never keep absurd tiny tiles (e.g. 16×22 @ 96px).
            if manifest.columns == nil || manifest.rows == nil {
                if let inferred = Self.inferGrid(sheetURL: sheetURL) {
                    manifest.columns = inferred.cols
                    manifest.rows = inferred.rows
                    manifest.frameWidth = inferred.fw
                    manifest.frameHeight = inferred.fh
                } else {
                    manifest.columns = 1
                    manifest.rows = 1
                }
            } else {
                let cols = max(1, manifest.columns ?? 1)
                let rows = max(1, manifest.rows ?? 1)
                let fw = manifest.frameWidth ?? 0
                let fh = manifest.frameHeight ?? 0
                if PetManifestSafety.cellCount(columns: cols, rows: rows) == nil
                    || (fw > 0 && fw < 140)
                    || (fh > 0 && fh < 140) {
                    if let inferred = Self.inferGrid(sheetURL: sheetURL) {
                        manifest.columns = inferred.cols
                        manifest.rows = inferred.rows
                        manifest.frameWidth = inferred.fw
                        manifest.frameHeight = inferred.fh
                    } else {
                        manifest.columns = 1
                        manifest.rows = 1
                        manifest.frameWidth = nil
                        manifest.frameHeight = nil
                    }
                }
            }
            // Default mood map when multi-frame
            guard let cells = PetManifestSafety.cellCount(
                columns: manifest.columns ?? 1,
                rows: manifest.rows ?? 1
            ), Self.frameReferencesAreValid(manifest, totalCells: cells) else {
                continue
            }
            if manifest.moodFrames == nil, cells >= 6 {
                manifest.moodFrames = [
                    "idle": 0, "talk": 1, "alert": 2,
                    "happy": 3, "sleep": 4, "scan": 5
                ]
            }
            list.append(PetPack(manifest: manifest, directory: dir, spritesheetURL: sheetURL))
        }
        packs = list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        // Drop stale active id
        if let id = activePackId, !packs.contains(where: { $0.id == id }) {
            activePackId = nil
        }
    }

    /// Import a .zip without blocking MainActor. Validation and extraction run
    /// on a utility task; only the final published state update returns here.
    @discardableResult
    func importZip(from zipURL: URL) async throws -> PetPack {
        let root = rootURL
        let pack = try await Task.detached(priority: .utility) {
            try Self.prepareAndInstall(zipURL: zipURL, rootURL: root)
        }.value
        reload()
        activePackId = pack.id
        guard let installed = packs.first(where: { $0.id == pack.id }) else {
            throw PetPackError.importFailed
        }
        return installed
    }

    private nonisolated static func prepareAndInstall(zipURL: URL, rootURL: URL) throws -> PetPack {
        try Task.checkCancellation()
        let fm = FileManager.default
        let archiveSize = try zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard archiveSize >= 0, UInt64(archiveSize) <= ImportLimit.archiveBytes else {
            throw PetPackError.archiveTooLarge
        }
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let tmp = fm.temporaryDirectory.appendingPathComponent("PetPackImport-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // 任意失败 / 取消 / 超时都清理临时目录
        defer { try? fm.removeItem(at: tmp) }

        let deadline = Date().addingTimeInterval(ImportLimit.processTimeout)
        try PetArchiveExtractor.extract(zipURL: zipURL, to: tmp, deadline: deadline)
        try Task.checkCancellation()

        // pet.json may be at root or one level down
        let jsonURL = findFile(named: "pet.json", under: tmp)
            ?? findFile(suffix: ".json", under: tmp)
        guard let jsonURL,
              let data = try? Data(contentsOf: jsonURL),
              var manifest = try? JSONDecoder().decode(PetPackManifest.self, from: data) else {
            throw PetPackError.invalidManifest
        }
        if manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifest.id = zipURL.deletingPathExtension().lastPathComponent
        }
        // 禁 path traversal：id 仅安全文件名
        guard let safeId = Self.sanitizedPackId(manifest.id) else {
            throw PetPackError.invalidManifest
        }
        manifest.id = safeId
        if manifest.displayName.isEmpty {
            manifest.displayName = manifest.id
        }

        let baseDir = jsonURL.deletingLastPathComponent()
        // 只认文件名，禁止 spritesheetPath 含 ../
        let sheetLeaf = (manifest.spritesheetPath.isEmpty ? "spritesheet.png" : manifest.spritesheetPath) as NSString
        let sheetName = sheetLeaf.lastPathComponent
        guard !sheetName.isEmpty, sheetName != "." , sheetName != "..", !sheetName.contains("/") else {
            throw PetPackError.missingSpritesheet
        }
        var sheetURL = baseDir.appendingPathComponent(sheetName)
        // 必须仍在解压目录内
        guard Self.isURL(sheetURL, under: tmp) else { throw PetPackError.missingSpritesheet }
        if !fm.fileExists(atPath: sheetURL.path) {
            if let alt = findFile(suffix: ".png", under: baseDir), Self.isURL(alt, under: tmp) {
                sheetURL = alt
                manifest.spritesheetPath = alt.lastPathComponent
            } else {
                throw PetPackError.missingSpritesheet
            }
        } else {
            manifest.spritesheetPath = sheetName
        }

        // Use author grid if present and sane; else infer conservatively.
        let authorGrid = (manifest.columns ?? 0) > 1 || (manifest.rows ?? 0) > 1
        if authorGrid {
            let cols = manifest.columns ?? 0
            let rows = manifest.rows ?? 0
            let fw = manifest.frameWidth ?? 0
            let fh = manifest.frameHeight ?? 0
            if PetManifestSafety.cellCount(columns: cols, rows: rows) == nil
                || (fw > 0 && fw < 140)
                || (fh > 0 && fh < 140) {
                // Bad author/old-infer values — re-infer
                if let inferred = Self.inferGrid(sheetURL: sheetURL) {
                    manifest.columns = inferred.cols
                    manifest.rows = inferred.rows
                    manifest.frameWidth = inferred.fw
                    manifest.frameHeight = inferred.fh
                } else {
                    manifest.columns = 1
                    manifest.rows = 1
                    manifest.frameWidth = nil
                    manifest.frameHeight = nil
                }
            }
        } else if let inferred = Self.inferGrid(sheetURL: sheetURL) {
            manifest.columns = inferred.cols
            manifest.rows = inferred.rows
            manifest.frameWidth = inferred.fw
            manifest.frameHeight = inferred.fh
        } else {
            manifest.columns = 1
            manifest.rows = 1
        }

        guard let cells = PetManifestSafety.cellCount(
            columns: manifest.columns ?? 1,
            rows: manifest.rows ?? 1
        ), Self.frameReferencesAreValid(manifest, totalCells: cells) else {
            throw PetPackError.invalidManifest
        }
        if manifest.moodFrames == nil, cells >= 6 {
            manifest.moodFrames = [
                "idle": 0, "talk": 1, "alert": 2,
                "happy": 3, "sleep": 4, "scan": 5
            ]
        }

        try PetArchiveExtractor.validateImageMegapixels(at: sheetURL)

        let dest = rootURL.appendingPathComponent(manifest.id, isDirectory: true)
        guard Self.isURL(dest, under: rootURL) else { throw PetPackError.importFailed }
        // 目标 ID 已存在时不覆盖
        if fm.fileExists(atPath: dest.path) {
            throw PetPackError.packExists
        }
        // 全部校验通过后再 atomic move
        let staged = rootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staged) }

        let destJSON = staged.appendingPathComponent("pet.json")
        let destSheet = staged.appendingPathComponent((manifest.spritesheetPath as NSString).lastPathComponent)
        guard Self.isURL(destJSON, under: staged), Self.isURL(destSheet, under: staged) else {
            throw PetPackError.importFailed
        }
        manifest.spritesheetPath = destSheet.lastPathComponent
        let encoded = try JSONEncoder().encode(manifest)
        if let obj = try? JSONSerialization.jsonObject(with: encoded),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try pretty.write(to: destJSON)
        } else {
            try encoded.write(to: destJSON)
        }
        try fm.copyItem(at: sheetURL, to: destSheet)
        try Task.checkCancellation()

        try fm.moveItem(at: staged, to: dest)
        return PetPack(manifest: manifest, directory: dest, spritesheetURL: dest.appendingPathComponent(destSheet.lastPathComponent))
    }

    func removePack(id: String) throws {
        guard let safe = Self.sanitizedPackId(id) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let dest = rootURL.appendingPathComponent(safe, isDirectory: true)
        guard Self.isURL(dest, under: rootURL) else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: dest, resultingItemURL: &trashedURL)
        // Selection changes only after the recoverable move succeeded.
        if activePackId == safe || activePackId == id { activePackId = nil }
        reload()
    }

    /// Pack id: only alnum / . _ -；禁 path 穿越
    nonisolated static func sanitizedPackId(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 64 else { return nil }
        guard t != "." , t != ".." else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return t
    }

    nonisolated static func isURL(_ url: URL, under root: URL) -> Bool {
        let u = url.resolvingSymlinksInPath().standardizedFileURL.path
        let r = root.resolvingSymlinksInPath().standardizedFileURL.path
        return u == r || u.hasPrefix(r + "/")
    }

    private nonisolated static func frameReferencesAreValid(
        _ manifest: PetPackManifest,
        totalCells: Int
    ) -> Bool {
        guard PetManifestSafety.frameMapIsValid(manifest.moodFrames, totalCells: totalCells) else {
            return false
        }
        return manifest.animations?.values.allSatisfy { clip in
            PetManifestSafety.resolvedFrames(
                frames: clip.frames,
                start: clip.start,
                count: clip.count,
                totalCells: totalCells
            ) != nil
        } ?? true
    }

    func selectBuiltIn() {
        activePackId = nil
    }

    func selectPack(id: String) {
        guard packs.contains(where: { $0.id == id }) else { return }
        activePackId = id
    }

    // MARK: - Grid inference

    // Prefer near-square cells in 160…400px range; avoid micro tiles.
    nonisolated static func inferGrid(sheetURL: URL) -> (cols: Int, rows: Int, fw: Int, fh: Int)? {
        guard let img = NSImage(contentsOf: sheetURL),
              let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? img.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else { return nil }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 64, h > 64 else { return nil }

        var best: (cols: Int, rows: Int, fw: Int, fh: Int, score: Double)?
        for cols in 2...12 {
            guard w % cols == 0 else { continue }
            let fw = w / cols
            guard (160...420).contains(fw) else { continue }
            for rows in 2...16 {
                guard h % rows == 0 else { continue }
                let fh = h / rows
                guard (160...480).contains(fh) else { continue }
                let aspect = Double(fw) / Double(fh)
                guard aspect > 0.65, aspect < 1.35 else { continue }
                let cells = cols * rows
                let score = Double(cells) - abs(1.0 - aspect) * 20.0 + (cells >= 24 ? 8 : 0)
                if best == nil || score > best!.score {
                    best = (cols, rows, fw, fh, score)
                }
            }
        }
        if let b = best {
            return (b.cols, b.rows, b.fw, b.fh)
        }
        return (1, 1, w, h)
    }

    // MARK: - File helpers

    private nonisolated static func findFile(named name: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }

    private nonisolated static func findFile(suffix: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en {
            if url.pathExtension.lowercased() == suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                || url.lastPathComponent.lowercased().hasSuffix(suffix.lowercased()) {
                // Prefer png images / json
                return url
            }
        }
        return nil
    }
}

// PetPackError / PetArchiveExtractor → PetArchiveKit（M10-1 可测安全解压）

// MARK: - Asset resolution (built-in + packs)

extension PetAssets {
    /// Prefer active custom pack frame; else bundle assets.
    /// - Parameter preferPack: false = always use built-in (for skin picker cards).
    @MainActor
    static func resolvedImage(for mood: PetMood, skin: PetSkin, preferPack: Bool = true) -> NSImage? {
        if preferPack,
           let pack = PetPackStore.shared.activePack,
           let img = pack.frameImage(mood: mood) {
            return img
        }
        return image(for: mood, skin: skin)
    }
}
