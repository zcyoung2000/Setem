import Foundation
import OSLog

private final class FailoverCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

/// One segment's recognition; microphone and UI ownership remain in DictationSession.
@MainActor
final class DictationFailover {
    private static let log = Logger(subsystem: "do.j3.openvoice", category: "Failover")
    struct Policy {
        var progressDelay: TimeInterval = 4
        var finalDelay: TimeInterval = 2
        static let automatic = Policy()
    }
    private let pool: DictationEnginePool
    private let replayPool: DictationEnginePool
    private let policy: Policy
    private let sleep: (TimeInterval) async throws -> Void
    private let isSpeech: ([Int16]) -> Bool
    private let captureFailure: () -> String?
    private let cancellation = FailoverCancellation()
    private let diagnosticID = UUID().uuidString
    private var candidates: [Channel] = []
    private var nextCandidate = 0
    private var frames: [[Int16]] = []
    private var outputs: [UUID: AsyncStream<[Int16]>.Continuation] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pump: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var watchdogGeneration = 0
    private var sourceEnded = false
    private var speechSeen = false
    private var finished = false
    private var previewAttempt: UUID?
    private var primaryAttempt: UUID?
    private var preview = ""
    private var partial: (String) -> Void = { _ in }
    private var reply: CheckedContinuation<String, Error>?
    private struct Success {
        let text: String
        let engine: ASREngine
        let channel: Channel
        let pool: DictationEnginePool
    }

    init(pool: DictationEnginePool, replayPool: DictationEnginePool? = nil,
         policy: Policy = .automatic,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         isSpeech: @escaping ([Int16]) -> Bool = { Recorder.level($0) > 0.08 },
         captureFailure: @escaping () -> String? = { nil }) {
        self.pool = pool
        self.replayPool = replayPool ?? pool
        self.policy = policy
        self.sleep = sleep
        self.isSpeech = isSpeech
        self.captureFailure = captureFailure
    }

    func run(audio: AsyncStream<[Int16]>, channel: Channel, partial: @escaping (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        candidates = channel == .offline ? [.offline] : [channel] + [Channel.doubao, .wetype, .qwen].filter { $0 != channel }
        self.partial = partial
        let cancellation = cancellation
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply = continuation
                guard !cancellation.isCancelled else { cancel(); return }
                pump = Task { [weak self] in
                    for await frame in audio {
                        guard !Task.isCancelled, let self, !self.finished else { return }
                        self.frames.append(frame)
                        self.outputs.values.forEach { $0.yield(frame) }
                        if self.isSpeech(frame) {
                            self.speechSeen = true
                            if self.watchdog == nil { self.arm(self.policy.progressDelay) }
                        }
                    }
                    self?.endAudio()
                }
                launchNext(reason: "primary")
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            Task { @MainActor in self?.cancel() }
        }
        try Task.checkCancellation()
        return result
    }

    private func launchNext(reason: String) {
        guard !finished, !cancellation.isCancelled else { cancel(); return }
        if let failure = captureFailure(), nextCandidate > 0 {
            // Input loss cannot be repaired by opening another ASR channel. Let
            // already-running providers finalize the audio they actually received.
            if tasks.isEmpty { finish(.failure(ASRError(failure))) }
            return
        }
        guard nextCandidate < candidates.count else {
            if tasks.isEmpty {
                finish(.failure(ASRError("暂时无法完成识别，请检查网络后重试")))
            }
            return
        }
        let channel = candidates[nextCandidate]
        let ownPool = nextCandidate == 0 ? pool : replayPool
        nextCandidate += 1
        let lease = ownPool.take(channel)
        let id = UUID()
        if nextCandidate == 1 { primaryAttempt = id }
        previewAttempt = id
        let (audio, output) = AsyncStream<[Int16]>.makeStream()
        frames.forEach { output.yield($0) }
        if sourceEnded { output.finish() }
        else { outputs[id] = output }
        Self.log.notice("attempt segment=\(self.diagnosticID, privacy: .public) channel=\(channel.rawValue, privacy: .public) reason=\(reason, privacy: .public) frames=\(self.frames.count)")
        tasks[id] = Task { [weak self] in
            do {
                await lease.ready()
                try Task.checkCancellation()
                let text = try await lease.engine.run(audio: audio) { [weak self] text in
                    DispatchQueue.main.async { [weak self] in self?.update(text, attempt: id) }
                }
                try Task.checkCancellation()
                DispatchQueue.main.async { [weak self] in
                    self?.complete(.success(text), attempt: id, channel: channel, engine: lease.engine, pool: ownPool)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.complete(.failure(error), attempt: id, channel: channel, engine: lease.engine, pool: ownPool)
                }
            }
        }
        if sourceEnded { arm(policy.finalDelay) }
        else if speechSeen { arm(policy.progressDelay) }
    }

    private func update(_ text: String, attempt: UUID) {
        guard !finished, !cancellation.isCancelled, previewAttempt == attempt,
              !text.isEmpty, !preview.utf16.elementsEqual(text.utf16) else { return }
        preview = text
        partial(text)
        if !sourceEnded { invalidateWatchdog() }
    }

    private func complete(_ result: Result<String, Error>, attempt: UUID, channel: Channel,
                          engine: ASREngine, pool: DictationEnginePool) {
        guard !finished, !cancellation.isCancelled else { cancel(); return }
        tasks[attempt] = nil
        outputs.removeValue(forKey: attempt)?.finish()
        switch result {
        case .success(let text):
            if text.isEmpty, attempt != primaryAttempt {
                launchNext(reason: "empty-backup")
                return
            }
            let success = Success(text: text, engine: engine, channel: channel, pool: pool)
            win(success)
        case .failure(let error):
            if error is CancellationError { finish(.failure(error)); return }
            Self.log.notice("failed segment=\(self.diagnosticID, privacy: .public) channel=\(channel.rawValue, privacy: .public) code=\((error as NSError).code)")
            launchNext(reason: "failure")
        }
    }

    private func endAudio() {
        guard !finished else { return }
        sourceEnded = true
        outputs.values.forEach { $0.finish() }
        outputs.removeAll()
        if captureFailure() == nil { arm(policy.finalDelay) }
        else { invalidateWatchdog() }
    }

    private func arm(_ delay: TimeInterval) {
        invalidateWatchdog()
        guard nextCandidate < candidates.count else { return }
        let generation = watchdogGeneration
        let sleep = sleep
        watchdog = Task { [weak self] in
            do { try await sleep(delay); try Task.checkCancellation() } catch { return }
            guard let self, !self.finished, self.watchdogGeneration == generation else { return }
            self.watchdog = nil
            self.launchNext(reason: self.sourceEnded ? "final-deadline" : "progress-deadline")
        }
    }

    private func invalidateWatchdog() {
        watchdogGeneration += 1
        watchdog?.cancel()
        watchdog = nil
    }

    private func win(_ success: Success) {
        guard !cancellation.isCancelled else { cancel(); return }
        if captureFailure() == nil { success.pool.reuse(success.engine, channel: success.channel) }
        Self.log.notice("finished segment=\(self.diagnosticID, privacy: .public) channel=\(success.channel.rawValue, privacy: .public) attempts=\(self.nextCandidate)")
        finish(.success(success.text))
    }

    private func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        invalidateWatchdog()
        pump?.cancel(); pump = nil
        outputs.values.forEach { $0.finish() }; outputs.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        frames.removeAll()
        let continuation = reply; reply = nil
        continuation?.resume(with: result)
    }
}
