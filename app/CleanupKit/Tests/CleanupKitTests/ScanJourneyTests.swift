import XCTest
@testable import CleanupKit

final class ScanJourneyTests: XCTestCase {
    func testStoppedJourneyRejectsLateEventsAndResumesOnlyUnfinishedWork() {
        var journey = ScanJourney()
        let started = Date(timeIntervalSince1970: 123)
        journey.begin(["a", "b"], now: started)
        journey.start("a"); journey.complete("a", count: 3)
        journey.start("b"); journey.stop()
        journey.complete("b", count: 99)
        journey.finish()
        XCTAssertEqual(journey.status, .stopped)
        XCTAssertEqual(journey.completedIDs, ["a"])
        journey.begin(["a", "b"], resuming: true)
        XCTAssertEqual(journey.startedAt, started)
        XCTAssertEqual(journey.stages.first?.count, 3)
        journey.start("b"); journey.complete("b", count: 2); journey.finish()
        XCTAssertEqual(journey.status, .complete)
    }

    func testMissingAndPartialStagesCannotLookComplete() {
        var journey = ScanJourney()
        journey.begin(["a", "b"])
        journey.complete("a")
        journey.finish()
        XCTAssertEqual(journey.status, .partial)
        journey.begin(["a", "b"])
        XCTAssertTrue(journey.completedIDs.isEmpty)
        journey.complete("a", partial: true); journey.complete("b"); journey.finish()
        XCTAssertEqual(journey.status, .partial)
    }

    func testAllAIKindsHaveOneDataCategoryWithoutChangingSelectionPolicy() {
        for kind in AIDataKind.allCases {
            let candidate = AICleanupCandidate(tool: .codex, kind: kind, title: "Fixture",
                resources: [], state: .reviewOnly, reason: "fixture", contextPath: "/Home/.codex/data")
            XCTAssertTrue(AIDataSection.allCases.contains(candidate.dataSection))
            XCTAssertFalse(candidate.canSelect)
        }
        XCTAssertEqual(AIDataSection.classify(kind: .cache, path: "/Home/Library/Caches/Cursor/Cache"), .appData)
        XCTAssertEqual(AIDataSection.classify(kind: .cache, path: "/Home/.cache/kimi"), .cliData)
        XCTAssertEqual(AIDataSection.classify(kind: .cache, path: "/Home/Library/Caches/kimi"), .cliData)
        XCTAssertEqual(AIDataSection.classify(kind: .conversation, path: "/Home/Library/Conversations"), .conversations)
        XCTAssertEqual(AIDataSection.classify(kind: .model, path: "/Home/.ollama/models"), .models)
        XCTAssertEqual(AIDataSection.classify(kind: .worktree, path: "/Home/.cursor/worktrees"), .worktrees)
    }
}
