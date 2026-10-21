import Foundation

/// Serializes the two disk-heavy junk scans (Cleanup and Diagnostic).
/// Callers remain cancellable while waiting for, or holding, the permit.
public actor DiskScanCoordinator {
    public static let shared = DiskScanCoordinator()

    private var activeToken: UUID?
    private var waiters: [(id: UUID, continuation: CheckedContinuation<UUID?, Never>)] = []

    public init() {}

    public func withPermit<T: Sendable>(
        retainingCancelledResult: Bool = false,
        _ operation: @Sendable () async -> T
    ) async -> T? {
        guard !Task.isCancelled else { return nil }
        guard let token = await acquire() else { return nil }
        let value = await operation()
        release(token)
        return Task.isCancelled && !retainingCancelledResult ? nil : value
    }

    private func acquire() async -> UUID? {
        let id = UUID()
        if activeToken == nil {
            activeToken = id
            return id
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                waiters.append((id, continuation))
                // Cancellation may have raced with the append. Resolve it here as
                // well as in onCancel, ensuring a waiter can never remain suspended.
                if Task.isCancelled, let index = waiters.firstIndex(where: { $0.id == id }) {
                    let waiter = waiters.remove(at: index)
                    waiter.continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func release(_ token: UUID) {
        guard activeToken == token else { return }
        if waiters.isEmpty {
            activeToken = nil
        } else {
            let next = waiters.removeFirst()
            activeToken = next.id
            next.continuation.resume(returning: next.id)
        }
    }
}
