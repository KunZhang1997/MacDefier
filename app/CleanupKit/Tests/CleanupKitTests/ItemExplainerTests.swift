import XCTest
@testable import CleanupKit

final class ItemExplainerTests: XCTestCase {
    func testSpeakSendBuildScratchPathStaysTemporary() {
        let item = CleanableItem(
            name: "speaksend-speed-tests",
            path: "/tmp/speaksend-speed-tests",
            bytes: 469 * 1024 * 1024,
            category: .temp,
            isSelected: false
        )

        XCTAssertEqual(item.displayTitle, "临时 · speaksend-speed-tests")
        XCTAssertEqual(item.whatIsIt, "临时目录里的短命文件")
        XCTAssertEqual(item.risk, .caution)
    }

    func testOllamaNamedBuildScratchPathStaysTemporary() {
        let item = CleanableItem(
            name: "speaksend-bugbot-ollama-delete-20260826",
            path: "/tmp/speaksend-bugbot-ollama-delete-20260826",
            bytes: 469 * 1024 * 1024,
            category: .temp,
            isSelected: false
        )

        XCTAssertEqual(item.displayTitle, "临时 · speaksend-bugbot-ollama-delete-20260826")
        XCTAssertEqual(item.whatIsIt, "临时目录里的短命文件")
        XCTAssertEqual(item.risk, .caution)
    }

    func testSpeakSendNameAloneDoesNotMeanLocalModel() {
        let item = CleanableItem(
            name: "speaksend-cache",
            path: "/Users/test/Library/Caches/speaksend-cache",
            bytes: 1024,
            category: .userCache,
            isSelected: false
        )

        XCTAssertNotEqual(item.displayTitle, "本地模型文件")
        XCTAssertNotEqual(item.whatIsIt, "应用下载到本机的语音/大语言模型文件")
    }

    func testManagedModelsPathIsStillRecognizedAsLocalModel() {
        let item = CleanableItem(
            name: "ggml-large.bin",
            path: "/Users/test/Library/Application Support/SpeakSend/ManagedModels/ggml-large.bin",
            bytes: 500 * 1024 * 1024,
            category: .largeAppData,
            isSelected: false
        )

        XCTAssertEqual(item.displayTitle, "本地模型文件")
        XCTAssertEqual(item.whatIsIt, "应用下载到本机的语音/大语言模型文件")
        XCTAssertEqual(item.risk, .caution)
    }

    func testPnpmIsNotMisclassifiedAsNpmCache() {
        XCTAssertEqual(
            ItemExplainer.classify(
                name: "pnpm store",
                path: "/Users/test/Library/pnpm/store",
                category: .node
            ),
            .devDependencyCache
        )
        XCTAssertEqual(
            ItemExplainer.classify(
                name: "pnpm",
                path: "/Users/test/.cache/pnpm",
                category: .userCache
            ),
            .devDependencyCache
        )
        XCTAssertEqual(
            ItemExplainer.classify(
                name: "npm cache",
                path: "/Users/test/.npm",
                category: .node
            ),
            .npmCache
        )

        let pnpmItem = CleanableItem(
            name: "pnpm store",
            path: "/Users/test/Library/pnpm/store",
            bytes: 1024,
            category: .node,
            isSelected: false
        )
        XCTAssertEqual(pnpmItem.displayTitle, "开发依赖缓存")
        XCTAssertNotEqual(pnpmItem.displayTitle, "npm 包缓存")
    }

    func testCleanableItemCachesIsDirectoryAtInit() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("IsDir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let tempFile = tempDir.appendingPathComponent("sample.bin")
        try Data([1, 2, 3]).write(to: tempFile)

        let dirItem = CleanableItem(name: "dir", path: tempDir.path, bytes: 1, category: .temp, isSelected: false)
        let fileItem = CleanableItem(name: "sample.bin", path: tempFile.path, bytes: 3, category: .temp, isSelected: false)
        let explicitOverride = CleanableItem(
            name: "virtual",
            path: tempDir.appendingPathComponent("nonexistent").path,
            bytes: 0,
            category: .temp,
            isSelected: false,
            isDirectory: true
        )

        XCTAssertTrue(dirItem.isDirectory)
        XCTAssertFalse(fileItem.isDirectory)
        XCTAssertTrue(explicitOverride.isDirectory)
    }
}
