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
}
