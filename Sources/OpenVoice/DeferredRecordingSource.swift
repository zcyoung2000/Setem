import Foundation

/// State belongs to one capture even after the user stops and starts another.
final class RecordingPreparation {
    private let lock = NSLock()
    private var waiting = true
    private var cancelled = false
    private var error: String?
    var isPreparing: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return error }
    func ready() -> Bool {
        lock.lock(); defer { lock.unlock() }
        waiting = false
        return !cancelled
    }
    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        waiting = false
        if !cancelled { self.error = error.localizedDescription }
    }
    func cancel() -> (first: Bool, preparing: Bool) {
        lock.lock(); defer { lock.unlock() }
        let first = !cancelled
        cancelled = true
        return (first, waiting)
    }
}

/// Heavy VoiceProcessingIO setup never runs inside a CGEvent tap or the UI loop.
/// One serial hardware queue also orders old teardown before the next startup.
final class DeferredRecordingSource: RecordingSource {
    let preparation = RecordingPreparation()
    private let input: RecordingSource
    private let queue: OperationQueue
    private var output: AsyncStream<[Int16]>.Continuation?
    private var deviceStopped = false // hardware queue only
    var onLevel: ((Float) -> Void)?
    var onReady: (() -> Void)?

    init(_ input: RecordingSource, queue: OperationQueue) {
        self.input = input
        self.queue = queue
    }

    func start() throws -> AsyncStream<[Int16]> {
        let (stream, output) = AsyncStream<[Int16]>.makeStream()
        self.output = output
        let preparation = preparation
        let level = onLevel
        input.onLevel = { value in
            if !preparation.isCancelled { level?(value) }
        }
        enqueue { [self] in
            guard !preparation.isCancelled else { output.finish(); return }
            do {
                let audio = try input.start()
                guard preparation.ready() else {
                    stopDevice()
                    output.finish()
                    return
                }
                onReady?()
                Task.detached {
                    for await frame in audio { output.yield(frame) }
                    output.finish()
                }
            } catch {
                stopDevice()
                preparation.fail(error)
                output.finish()
            }
        }
        return stream
    }

    func stop() {
        let cancelled = preparation.cancel()
        guard cancelled.first else { return }
        if cancelled.preparing { output?.finish() }
        enqueue { [self] in stopDevice() }
    }

    private func enqueue(_ work: @escaping () -> Void) {
        let operation = BlockOperation(block: work)
        // OperationQueue alone does not promise FIFO ordering.
        for prior in queue.operations { operation.addDependency(prior) }
        queue.addOperation(operation)
    }

    private func stopDevice() {
        guard !deviceStopped else { return }
        deviceStopped = true
        input.stop()
    }
}
