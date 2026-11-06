import Foundation

enum QwenReadError: LocalizedError {
    case timeout
    var errorDescription: String? { "服务器响应超时" }
}

/// A cancelled read releases only its waiter, not the connection or a future round's
/// bytes. NWConnection has one permanent read pump; consumers can stop independently.
actor QwenInbox {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Data, Error>
        let timer: Task<Void, Never>
    }
    private var chunks = FIFOBuffer<Data>()
    private var waiter: Waiter?
    private var terminal: Error?
    private let sleep: (TimeInterval) async throws -> Void

    init(sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    func push(_ data: Data) {
        guard terminal == nil, !data.isEmpty else { return }
        if let waiting = waiter {
            waiter = nil
            waiting.timer.cancel()
            waiting.continuation.resume(returning: data)
        } else { chunks.append(data) }
    }
    func finish(_ error: Error) {
        guard terminal == nil else { return }
        terminal = error
        if let waiting = waiter {
            waiter = nil
            waiting.timer.cancel()
            waiting.continuation.resume(throwing: error)
        }
    }
    func read(timeout: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if let chunk = chunks.popFirst() { continuation.resume(returning: chunk); return }
                if let terminal { continuation.resume(throwing: terminal); return }
                guard waiter == nil else { continuation.resume(throwing: ASRError("千问连接存在并发读取")); return }
                let sleep = self.sleep
                let timer = Task { [weak self] in
                    do { try await sleep(max(0, timeout)) } catch { return }
                    await self?.expire(id)
                }
                waiter = Waiter(id: id, continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        guard let waiting = waiter, waiting.id == id else { return }
        waiter = nil
        waiting.timer.cancel()
        waiting.continuation.resume(throwing: CancellationError())
    }
    private func expire(_ id: UUID) {
        guard let waiting = waiter, waiting.id == id else { return }
        waiter = nil
        waiting.continuation.resume(throwing: QwenReadError.timeout)
    }
}
