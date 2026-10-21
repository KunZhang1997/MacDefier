// PetArchiveExtractor — stream-safe ZIP extract via ZIPFoundation (no /usr/bin/unzip).
// M10-1: Rejects symlink/hardlink/device, zip-slip, absolute paths, .., NUL, backslash.
// Fail-closed: entry list count must equal extracted count; post-tree audit rejects any symlink
// or path that escapes destination (resolvingSymlinksInPath).

import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

public enum PetArchiveExtractor {
    public enum Limit {
        public static let archiveBytes: UInt64 = 100 * 1_024 * 1_024
        public static let entryCount = 500
        public static let expandedBytes: UInt64 = 500 * 1_024 * 1_024
        public static let imagePixels: UInt64 = 64_000_000
        public static let timeout: TimeInterval = 45
        public static let chunkBytes = 64 * 1024
    }

    /// 将 ZIP 安全解压到 `destination`（必须为空目录）。任意失败由调用方 defer 清理。
    public static func extract(
        zipURL: URL,
        to destination: URL,
        deadline: Date = Date().addingTimeInterval(Limit.timeout)
    ) throws {
        try Task.checkCancellation()
        let fm = FileManager.default

        let archiveSize = try zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard archiveSize >= 0, UInt64(archiveSize) <= Limit.archiveBytes else {
            throw PetPackError.archiveTooLarge
        }

        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw PetPackError.unzipFailed
        }

        // 预扫：条目数、类型、路径安全、声明解压大小（仅作上界提示，不单独信任）
        var entryList: [Entry] = []
        var declaredUncompressed: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            if Date() >= deadline { throw PetPackError.unzipTimedOut }
            try validateEntryMetadata(entry)
            declaredUncompressed = declaredUncompressed &+ UInt64(entry.uncompressedSize)
            if declaredUncompressed > Limit.expandedBytes {
                throw PetPackError.expandedTooLarge
            }
            entryList.append(entry)
            if entryList.count > Limit.entryCount {
                throw PetPackError.tooManyEntries
            }
        }
        guard !entryList.isEmpty else { throw PetPackError.unzipFailed }

        var writtenBytes: UInt64 = 0
        var writtenEntries = 0
        let rootResolved = destination.resolvingSymlinksInPath().standardizedFileURL

        for entry in entryList {
            try Task.checkCancellation()
            if Date() >= deadline { throw PetPackError.unzipTimedOut }

            let rel = entry.path
            let destURL = try resolvedDestination(root: rootResolved, entryPath: rel)

            switch entry.type {
            case .directory:
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                // 必须仍是目录且不逃逸（防父路径被换）
                try assertContainedRegularOrDirectory(destURL, root: rootResolved, expectDirectory: true)
                writtenEntries += 1
            case .file:
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // 流式写出：每个 chunk 累计真实展开字节；从不创建 symlink
                guard let out = OutputStream(url: destURL, append: false) else {
                    throw PetPackError.unzipFailed
                }
                out.open()
                defer { out.close() }

                _ = try archive.extract(entry, consumer: { data in
                    try Task.checkCancellation()
                    if Date() >= deadline { throw PetPackError.unzipTimedOut }
                    let n = data.count
                    guard n > 0 else { return }
                    writtenBytes = writtenBytes &+ UInt64(n)
                    if writtenBytes > Limit.expandedBytes {
                        throw PetPackError.expandedTooLarge
                    }
                    try data.withUnsafeBytes { raw in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                            throw PetPackError.unzipFailed
                        }
                        var offset = 0
                        while offset < n {
                            let wrote = out.write(base.advanced(by: offset), maxLength: n - offset)
                            if wrote <= 0 { throw PetPackError.unzipFailed }
                            offset += wrote
                        }
                    }
                })
                // 写出后必须是普通文件，禁止变成 symlink
                try assertContainedRegularOrDirectory(destURL, root: rootResolved, expectDirectory: false)
                writtenEntries += 1
            default:
                // symlink / unknown → 拒绝（fail-closed；不进入 entryList 本应已拦）
                throw PetPackError.unzipFailed
            }

            if writtenEntries > Limit.entryCount {
                throw PetPackError.tooManyEntries
            }
        }

        // M10-1: list 数 ≠ extract 数 → fail-closed
        guard writtenEntries == entryList.count else {
            throw PetPackError.unzipFailed
        }

        // 全树审计：无 symlink、路径均在 root 内、仅 regular/dir
        try auditExtractedTree(root: rootResolved, deadline: deadline)

        // 全部图片元数据：任一超过 64 MP 失败
        try validateAllImagesUnder(rootResolved, deadline: deadline)
    }

    // MARK: - Entry validation

    private static func validateEntryMetadata(_ entry: Entry) throws {
        let path = entry.path
        // NUL / 反斜杠 / 绝对路径 / ..
        if path.contains("\0") { throw PetPackError.unzipFailed }
        if path.contains("\\") { throw PetPackError.unzipFailed }
        if path.hasPrefix("/") || path.hasPrefix("~") { throw PetPackError.unzipFailed }
        // Windows drive-style
        if path.count >= 2, path[path.index(path.startIndex, offsetBy: 1)] == ":" {
            throw PetPackError.unzipFailed
        }
        // 双斜杠展开差异（fopen vs URL.standardized）— 直接拒
        if path.contains("//") { throw PetPackError.unzipFailed }

        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for (i, part) in parts.enumerated() {
            if part == ".." || part == "." { throw PetPackError.unzipFailed }
            // 允许末尾空段表示目录（foo/）
            if part.isEmpty {
                if i != parts.count - 1 { throw PetPackError.unzipFailed }
            }
        }

        // 仅允许 regular file / directory；symlink 及未知类型一律拒绝
        switch entry.type {
        case .file, .directory:
            break
        default:
            throw PetPackError.unzipFailed
        }
    }

    /// 按组件拼接路径，避免 `//` 与 `appendingPathComponent` 整段注入差异。
    private static func resolvedDestination(root: URL, entryPath: String) throws -> URL {
        var rel = entryPath
        while rel.hasSuffix("/") { rel = String(rel.dropLast()) }
        if rel.isEmpty {
            return root
        }

        var dest = root
        for part in rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == ".." || part == "." || part.isEmpty { throw PetPackError.unzipFailed }
            if part.contains("\0") { throw PetPackError.unzipFailed }
            dest = dest.appendingPathComponent(part, isDirectory: false)
        }

        try assertPath(dest, under: root)
        return dest
    }

    private static func assertPath(_ url: URL, under root: URL) throws {
        // 对齐 ZIPFoundation isContained：先压 // 再 standardized
        let sanitized = url.path.replacingOccurrences(of: "//", with: "/")
        let std = URL(fileURLWithPath: sanitized).standardizedFileURL.path
        let rootStd = root.standardizedFileURL.path
        guard std == rootStd || std.hasPrefix(rootStd + "/") else {
            throw PetPackError.unzipFailed
        }
    }

    private static func assertContainedRegularOrDirectory(
        _ url: URL,
        root: URL,
        expectDirectory: Bool
    ) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw PetPackError.unzipFailed
        }
        // 符号链接：fileExists 跟随；用 resourceValues 查
        let vals = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        if vals.isSymbolicLink == true {
            throw PetPackError.unzipFailed
        }
        if expectDirectory {
            guard vals.isDirectory == true || isDir.boolValue else {
                throw PetPackError.unzipFailed
            }
        } else {
            guard vals.isRegularFile == true else {
                throw PetPackError.unzipFailed
            }
        }
        // 解析后仍须在 root 内（防中间目录被换 symlink）
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        try assertPath(resolved, under: root.resolvingSymlinksInPath().standardizedFileURL)
    }

    /// M10-1 post-check：扫整棵树，拒 symlink / 逃逸；不仅扫图片。
    private static func auditExtractedTree(root: URL, deadline: Date) throws {
        let fm = FileManager.default
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard let en = fm.enumerator(
            at: rootResolved,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .isDirectoryKey
            ],
            options: [.skipsPackageDescendants]
        ) else {
            throw PetPackError.unzipFailed
        }

        for case let url as URL in en {
            try Task.checkCancellation()
            if Date() >= deadline { throw PetPackError.unzipTimedOut }

            let vals = try url.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey
            ])
            if vals.isSymbolicLink == true {
                throw PetPackError.unzipFailed
            }
            let isDir = vals.isDirectory == true
            let isReg = vals.isRegularFile == true
            guard isDir || isReg else {
                // socket / device / unknown → fail-closed
                throw PetPackError.unzipFailed
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            try assertPath(resolved, under: rootResolved)
        }
    }

    private static func validateAllImagesUnder(_ root: URL, deadline: Date) throws {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic"]
        for case let url as URL in en {
            try Task.checkCancellation()
            if Date() >= deadline { throw PetPackError.unzipTimedOut }
            let ext = url.pathExtension.lowercased()
            guard imageExts.contains(ext) else { continue }
            try validateImageMegapixels(at: url)
        }
    }

    public static func validateImageMegapixels(at url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PetPackError.importFailed
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            // An image-looking file whose metadata cannot be inspected is not
            // allowed to bypass the megapixel quota.
            throw PetPackError.importFailed
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value ?? 0
        try validateImageDimensions(width: w, height: h)
    }

    /// Internal pure boundary used by metadata validation and quota tests.
    /// Overflow is rejected instead of wrapping below the 64 MP threshold.
    static func validateImageDimensions(width: UInt64, height: UInt64) throws {
        guard width > 0, height > 0 else { throw PetPackError.importFailed }
        let pixels = width.multipliedReportingOverflow(by: height)
        if pixels.overflow || pixels.partialValue > Limit.imagePixels {
            throw PetPackError.imageTooLarge
        }
    }
}
