// M10-1: pet zip symlink / zip-slip must fail-closed on shipped PetArchiveExtractor.
// Run: cd app/PetArchiveKit && swift test

import Foundation
import XCTest
import ZIPFoundation
@testable import PetArchiveKit

final class PetArchiveExtractorTests: XCTestCase {
    private var scratch: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        scratch = fm.temporaryDirectory.appendingPathComponent(
            "PetArchiveM10-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? fm.removeItem(at: scratch)
        }
    }

    // MARK: - Helpers

    private func makeZip(named: String, build: (Archive) throws -> Void) throws -> URL {
        let zipURL = scratch.appendingPathComponent(named)
        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }
        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            XCTFail("create archive failed")
            throw PetPackError.unzipFailed
        }
        try build(archive)
        return zipURL
    }

    private func addFile(_ archive: Archive, path: String, data: Data) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .none,
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                guard start < end else { return Data() }
                return data.subdata(in: start..<end)
            }
        )
    }

    private func emptyDest() throws -> URL {
        let dest = scratch.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        return dest
    }

    // MARK: - Happy path

    func testExtractRegularFileOK() throws {
        let payload = Data("hello-pet".utf8)
        let zip = try makeZip(named: "ok.zip") { archive in
            try addFile(archive, path: "pet.json", data: payload)
        }
        let dest = try emptyDest()
        try PetArchiveExtractor.extract(zipURL: zip, to: dest)
        let out = dest.appendingPathComponent("pet.json")
        XCTAssertEqual(try Data(contentsOf: out), payload)
        let vals = try out.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        XCTAssertEqual(vals.isSymbolicLink, false)
        XCTAssertEqual(vals.isRegularFile, true)
    }

    // MARK: - M10-1 symlink rejected

    func testSymlinkEntryRejected() throws {
        let target = Data("/etc/passwd".utf8)
        let zip = try makeZip(named: "symlink.zip") { archive in
            try archive.addEntry(
                with: "evil-link",
                type: .symlink,
                uncompressedSize: Int64(target.count),
                compressionMethod: .none,
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, target.count)
                    guard start < end else { return Data() }
                    return target.subdata(in: start..<end)
                }
            )
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { err in
            XCTAssertEqual(err as? PetPackError, .unzipFailed)
        }
        // 不得在 dest 留下 symlink
        let link = dest.appendingPathComponent("evil-link")
        XCTAssertFalse(fm.fileExists(atPath: link.path))
    }

    func testSymlinkMixedWithRegularRejected() throws {
        let target = Data("/tmp".utf8)
        let zip = try makeZip(named: "mixed-symlink.zip") { archive in
            try addFile(archive, path: "pet.json", data: Data("{}".utf8))
            try archive.addEntry(
                with: "spritesheet.png",
                type: .symlink,
                uncompressedSize: Int64(target.count),
                compressionMethod: .none,
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, target.count)
                    guard start < end else { return Data() }
                    return target.subdata(in: start..<end)
                }
            )
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { err in
            XCTAssertEqual(err as? PetPackError, .unzipFailed)
        }
    }

    // MARK: - M10-1 zip-slip

    func testZipSlipDotDotRejected() throws {
        let zip = try makeZip(named: "slip.zip") { archive in
            try addFile(archive, path: "../escape.txt", data: Data("pwned".utf8))
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { err in
            XCTAssertEqual(err as? PetPackError, .unzipFailed)
        }
        let escaped = dest.deletingLastPathComponent().appendingPathComponent("escape.txt")
        // 即使同 scratch 下也不应写出
        if fm.fileExists(atPath: escaped.path) {
            let data = try? Data(contentsOf: escaped)
            XCTAssertNotEqual(data, Data("pwned".utf8), "zip-slip must not write outside dest")
        }
    }

    func testAbsolutePathRejected() throws {
        let zip = try makeZip(named: "abs.zip") { archive in
            try addFile(archive, path: "/tmp/macdefier-pet-abs.txt", data: Data("nope".utf8))
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { err in
            XCTAssertEqual(err as? PetPackError, .unzipFailed)
        }
    }

    func testNestedDotDotRejected() throws {
        let zip = try makeZip(named: "nested-slip.zip") { archive in
            try addFile(archive, path: "safe/../../outside.txt", data: Data("x".utf8))
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { err in
            XCTAssertEqual(err as? PetPackError, .unzipFailed)
        }
    }

    func testDoubleSlashPathRejected() throws {
        let zip = try makeZip(named: "doubleslash.zip") { archive in
            try addFile(archive, path: "foo//bar.txt", data: Data("x".utf8))
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { err in
            XCTAssertEqual(err as? PetPackError, .unzipFailed)
        }
    }

    // MARK: - Quotas still work

    func testEmptyArchiveRejected() throws {
        let zipURL = scratch.appendingPathComponent("empty.zip")
        guard Archive(url: zipURL, accessMode: .create) != nil else {
            return XCTFail("create failed")
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zipURL, to: dest)) { err in
            XCTAssertEqual(err as? PetPackError, .unzipFailed)
        }
    }

    func testMoreThanFiveHundredEntriesRejectedBeforeExtraction() throws {
        let zip = try makeZip(named: "too-many.zip") { archive in
            for index in 0...PetArchiveExtractor.Limit.entryCount {
                try addFile(archive, path: "frames/\(index).txt", data: Data([UInt8(index & 0xff)]))
            }
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { error in
            XCTAssertEqual(error as? PetPackError, .tooManyEntries)
        }
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: dest.path)) ?? [], [])
    }

    func testExpiredDeadlineStopsBeforeWriting() throws {
        let zip = try makeZip(named: "deadline.zip") { archive in
            try addFile(archive, path: "pet.json", data: Data("{}".utf8))
        }
        let dest = try emptyDest()
        XCTAssertThrowsError(
            try PetArchiveExtractor.extract(
                zipURL: zip,
                to: dest,
                deadline: Date(timeIntervalSinceNow: -1)
            )
        ) { error in
            XCTAssertEqual(error as? PetPackError, .unzipTimedOut)
        }
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: dest.path)) ?? [], [])
    }

    func testImageOverSixtyFourMegapixelsRejectedFromMetadata() throws {
        XCTAssertNoThrow(try PetArchiveExtractor.validateImageDimensions(width: 8_000, height: 8_000))
        XCTAssertThrowsError(try PetArchiveExtractor.validateImageDimensions(width: 8_001, height: 8_000)) { error in
            XCTAssertEqual(error as? PetPackError, .imageTooLarge)
        }
        XCTAssertThrowsError(try PetArchiveExtractor.validateImageDimensions(width: .max, height: 2)) { error in
            XCTAssertEqual(error as? PetPackError, .imageTooLarge)
        }
    }

    // MARK: - F3 CRC32 integrity verification

    func testTamperedUncompressedJSONRejectedAndCleansUpPartialFiles() throws {
        let firstEntry = Data("valid-readme-before-corruption".utf8)
        let jsonPayload = Data(#"{"id":"mr-defier","name":"Mister Defier","fps":12}"#.utf8)
        let zip = try makeZip(named: "tampered-uncompressed.zip") { archive in
            try archive.addEntry(with: "frames/", type: .directory, uncompressedSize: Int64(0), provider: { _, _ in Data() })
            try addFile(archive, path: "frames/readme.txt", data: firstEntry)
            try addFile(archive, path: "pet.json", data: jsonPayload)
        }

        // Flip one byte inside the uncompressed JSON payload without updating ZIP CRC32 headers.
        var archiveBytes = try Data(contentsOf: zip)
        let needle = Data("Mister Defier".utf8)
        let range = try XCTUnwrap(archiveBytes.range(of: needle))
        archiveBytes[range.lowerBound] ^= 0x01
        try archiveBytes.write(to: zip)

        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { error in
            XCTAssertEqual(error as? PetPackError, .corruptedArchive)
            XCTAssertEqual((error as? PetPackError)?.localizationKey, "pet.error.unzip_failed")
        }
        // Previously extracted directory and file entries must be cleaned up on corruption failure.
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: dest.path)) ?? [], [])
    }

    func testTamperedDeflateCompressedJSONRejectedAndCleansUpPartialFiles() throws {
        let firstEntry = Data("valid-sprite-placeholder".utf8)
        let repeatedJSON = #"{"id":"mr-defier","frames":["idle_0","idle_1","idle_2","idle_3","walk_0","walk_1"]}"#
        let jsonData = Data(String(repeating: repeatedJSON, count: 8).utf8)
        let zip = try makeZip(named: "tampered-deflate.zip") { archive in
            try addFile(archive, path: "first.txt", data: firstEntry)
            try archive.addEntry(
                with: "pet.json",
                type: .file,
                uncompressedSize: Int64(jsonData.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, jsonData.count)
                    guard start < end else { return Data() }
                    return jsonData.subdata(in: start..<end)
                }
            )
        }

        // Locate local file header (PK\x03\x04) for "pet.json" and flip a compressed payload byte.
        var archiveBytes = try Data(contentsOf: zip)
        let localSig = Data([0x50, 0x4B, 0x03, 0x04])
        var searchStart = archiveBytes.startIndex
        var payloadOffset: Int?
        while let sigRange = archiveBytes.range(of: localSig, options: [], in: searchStart..<archiveBytes.endIndex) {
            let h = sigRange.lowerBound
            guard h + 30 <= archiveBytes.count else { break }
            let nameLen = Int(archiveBytes[h + 26]) | (Int(archiveBytes[h + 27]) << 8)
            let extraLen = Int(archiveBytes[h + 28]) | (Int(archiveBytes[h + 29]) << 8)
            let nameStart = h + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd + extraLen < archiveBytes.count else { break }
            let name = String(data: archiveBytes.subdata(in: nameStart..<nameEnd), encoding: .utf8)
            if name == "pet.json" {
                payloadOffset = nameEnd + extraLen + 2
                break
            }
            searchStart = nameEnd + extraLen
        }
        let targetByteIndex = try XCTUnwrap(payloadOffset)
        archiveBytes[targetByteIndex] ^= 0xFF
        try archiveBytes.write(to: zip)

        let dest = try emptyDest()
        XCTAssertThrowsError(try PetArchiveExtractor.extract(zipURL: zip, to: dest)) { error in
            XCTAssertEqual(error as? PetPackError, .corruptedArchive)
        }
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: dest.path)) ?? [], [])
    }
}
