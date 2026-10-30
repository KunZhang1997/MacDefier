import Foundation

enum AppUpdateStage: Equatable {
    case idle
    case probing
    case available(String)
    case checking
    case downloading(Int?)
    case preparing(Int?)
    case waitingToInstall
    case installing
    case current
    case unavailable
    case failed
    case cancelled
    case development

    var isBusy: Bool {
        switch self {
        case .probing, .checking, .downloading, .preparing, .waitingToInstall, .installing: return true
        default: return false
        }
    }

    var isCancellable: Bool {
        switch self {
        case .checking, .downloading, .waitingToInstall: return true
        default: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .current, .unavailable, .failed, .cancelled, .development: return true
        default: return false
        }
    }

    var showsControl: Bool {
        switch self {
        case .available, .checking, .downloading, .preparing, .waitingToInstall, .installing, .failed:
            return true
        case .idle, .probing, .current, .unavailable, .cancelled, .development:
            return false
        }
    }
}

/// Transfer presentation only. The updater owns networking, validation and installation.
struct AppUpdateState: Equatable {
    private(set) var stage: AppUpdateStage = .idle
    private var expectedByteCount: UInt64?
    private var receivedByteCount: UInt64 = 0

    init() {}

    mutating func begin() {
        resetDownload()
        setStage(.checking)
    }

    mutating func beginDownload() {
        resetDownload()
        setStage(.downloading(nil))
    }

    mutating func expectBytes(_ bytes: UInt64) {
        guard case .downloading = stage else { return }
        expectedByteCount = bytes == 0 ? nil : bytes
        updateDownloadProgress()
    }

    mutating func receiveBytes(_ bytes: UInt64) {
        guard case .downloading = stage else { return }
        let (sum, overflow) = receivedByteCount.addingReportingOverflow(bytes)
        receivedByteCount = overflow ? UInt64.max : sum
        updateDownloadProgress()
    }

    mutating func prepare() {
        setStage(.preparing(nil))
    }

    mutating func extractionProgress(_ progress: Double) {
        guard case .preparing = stage else { return }
        guard progress.isFinite else { setStage(.preparing(nil)); return }
        let percentage = Int(min(1, max(0, progress)) * 100)
        setStage(.preparing(percentage))
    }

    mutating func setStage(_ stage: AppUpdateStage) {
        let next: AppUpdateStage
        switch stage {
        case .downloading(let value): next = .downloading(value.map { min(100, max(0, $0)) })
        case .preparing(let value): next = .preparing(value.map { min(100, max(0, $0)) })
        default: next = stage
        }
        if self.stage != next { self.stage = next }
    }

    private mutating func resetDownload() {
        expectedByteCount = nil
        receivedByteCount = 0
    }

    private mutating func updateDownloadProgress() {
        guard let expected = expectedByteCount, receivedByteCount > 0 else {
            setStage(.downloading(nil))
            return
        }
        guard receivedByteCount < expected else { setStage(.downloading(100)); return }
        // Full-width integer arithmetic avoids overflow and premature 100% from Double rounding.
        let fraction = receivedByteCount.multipliedFullWidth(by: 100)
        let percentage = Int(expected.dividingFullWidth(fraction).quotient)
        setStage(.downloading(percentage))
    }
}
