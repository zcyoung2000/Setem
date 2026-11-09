import Foundation
import OSLog

/// One dictation may contain several recordings while earlier recordings await their final text.
/// All shared state and capture ownership live here, rather than in engine task cleanup handlers.
@MainActor
final class DictationSession {
    struct Result: Equatable {
        let text: String
        let error: String?
        let sendsReturn: Bool
    }

    private let startCapture: () throws -> AsyncStream<[Int16]>
    private let stopCapture: () -> Void
    private let captureFailure: () -> (() -> String?)
    private let makeEngine: (Channel) -> ASREngine
    private let enginePool: DictationEnginePool?
    private let replayPool: DictationEnginePool
    private let failoverPolicy: DictationFailover.Policy?
    private let sleep: (TimeInterval) async throws -> Void
    private let timeout: TimeInterval
    private var generation = 0
    private var timeoutToken = 0
    private var transcript = DictationTranscript()
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var watchdog: Task<Void, Never>?
    private var recordingSegment: Int?
    private var sendOnFinish = false

    private(set) var isActive = false
    private(set) var channel: Channel = .doubao
    var isRecording: Bool { recordingSegment != nil }
    var text: String { transcript.text }

    var onUpdate: (String) -> Void = { _ in }
    var onFinish: (Result) -> Void = { _ in }
    var onCancel: (String, String?) -> Void = { _, _ in }
    var onCaptureChanged: (Bool) -> Void = { _ in }

    init(startCapture: @escaping () throws -> AsyncStream<[Int16]>,
         stopCapture: @escaping () -> Void,
         captureFailure: @escaping () -> (() -> String?) = { { nil } },
         makeEngine: @escaping (Channel) -> ASREngine = DictationSession.makeEngine,
         enginePool: DictationEnginePool? = nil,
         replayPool: DictationEnginePool? = nil,
         failoverPolicy: DictationFailover.Policy? = nil,
         timeout: TimeInterval = 15,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.captureFailure = captureFailure
        self.makeEngine = makeEngine
        self.enginePool = enginePool
        self.replayPool = replayPool ?? DictationEnginePool(factory: DictationSession.makeReplayEngine)
        self.failoverPolicy = failoverPolicy
        self.timeout = timeout
        self.sleep = sleep
    }

    nonisolated static func makeEngine(_ channel: Channel) -> ASREngine {
        switch channel {
        case .doubao: DoubaoEngine()
        case .wetype: WeTypeEngine()
        case .qwen: QwenEngine()
        case .offline: OfflineEngine(dedicatedWorker: true, keepsWorkerWarm: true)
        }
    }

    nonisolated static func makeReplayEngine(_ channel: Channel) -> ASREngine {
        makeFailoverEngine(channel, realtime: false)
    }

    nonisolated static func makeFailoverEngine(_ channel: Channel, realtime: Bool = true) -> ASREngine {
        switch channel {
        case .doubao: DoubaoEngine(requireFinalResult: true, realtime: realtime)
        case .qwen: QwenEngine(requireFinalResult: true, realtime: realtime)
        case .wetype: WeTypeEngine(realtime: realtime)
        case .offline: OfflineEngine(dedicatedWorker: true, keepsWorkerWarm: true)
        }
    }

    /// A second start while finalizing appends a segment; it never cancels a pending final.
    @discardableResult
    func start(channel: Channel, sendsReturn: Bool = false) throws -> Bool {
        guard !isRecording else { return false }
        // Failure to open the next recording must leave the pending session and timer intact.
        var audio = try startCapture()
        let debugName = DebugCapture.enabled ? DebugCapture.makeName() : nil
        if let debugName { audio = DebugCapture.tee(audio, name: debugName) }
        let captureFailure = self.captureFailure()
        invalidateTimeout()
        if !isActive {
            generation += 1
            transcript = DictationTranscript()
            self.channel = channel
            sendOnFinish = false
            isActive = true
        }
        sendOnFinish = sendOnFinish || sendsReturn
        let id = transcript.begin()
        let gen = generation
        recordingSegment = id
        onCaptureChanged(true)
        // Never share a mutable WebSocket/client between concurrent recordings.
        let channel = self.channel
        let pool = enginePool
        let failover = channel != .offline ? failoverPolicy.map {
            DictationFailover(pool: pool ?? DictationEnginePool(factory: makeEngine), replayPool: replayPool,
                              policy: $0, captureFailure: captureFailure)
        } : nil
        let lease = failover == nil ? pool?.take(channel) : nil
        let engine: ASREngine? = failover == nil ? (lease?.engine ?? makeEngine(channel)) : nil
        tasks[id] = Task { [weak self] in
            do {
                let partial: (String) -> Void = { [weak self] partial in
                    DispatchQueue.main.async { [weak self] in self?.update(partial, id: id, generation: gen) }
                }
                let text: String
                if let failover { text = try await failover.run(audio: audio, channel: channel, partial: partial) }
                else {
                    await lease?.ready()
                    try Task.checkCancellation()
                    text = try await engine!.run(audio: audio, partial: partial)
                }
                let failure = captureFailure()
                if let engine, !Task.isCancelled, failure == nil { pool?.reuse(engine, channel: channel) }
                if let debugName { DebugCapture.note("\(debugName) channel=\(channel.rawValue) final=\(text)") }
                // Use the same FIFO as partials, including when a vendor returns/throws immediately.
                DispatchQueue.main.async { [weak self] in
                    self?.complete(id: id, generation: gen, text: text, error: failure, captureFailed: failure != nil)
                }
            } catch {
                let failure = captureFailure()
                let message = failure ?? error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.complete(id: id, generation: gen, text: "", error: message, captureFailed: failure != nil)
                }
            }
        }
        return true
    }

    func end() {
        guard isRecording else { return }
        stopRecording(reason: "manual-stop")
        finishOrWait()
    }

    /// Invalidate ownership before cancelling: vendors may complete or throw much later.
    func cancel(_ message: String? = nil) {
        guard isActive else { return }
        let kept = text
        isActive = false
        generation += 1
        invalidateTimeout()
        let oldTasks = Array(tasks.values)
        tasks = [:]
        stopRecording(reason: "cancel")
        for task in oldTasks { task.cancel() }
        onCancel(kept, message)
    }

    private func update(_ text: String, id: Int, generation gen: Int) {
        guard isActive, generation == gen, !transcript.hasIdenticalPartial(id, text: text),
              transcript.update(id, text: text) != nil else { return }
        onUpdate(self.text)
    }

    private func complete(id: Int, generation gen: Int, text: String, error: String?, captureFailed: Bool = false) {
        guard isActive, generation == gen else { return }
        // Hardware failure is reported alongside the final captured text. The
        // provider's complete final still supersedes its last partial preview.
        if captureFailed, !text.isEmpty { _ = transcript.update(id, text: text) }
        guard transcript.finish(id, text: text, error: error, keepPartial: false) else { return }
        tasks[id] = nil
        // Finishing an older segment must not stop the recorder owned by a newer one.
        if transcript.finished || (captureFailed && recordingSegment == id) {
            stopRecording(reason: captureFailed ? "input-failed" : "provider-finished")
        }
        onUpdate(self.text)
        finishOrWait()
    }

    private func stopRecording(reason: String) {
        guard let segment = recordingSegment else { return }
        Logger(subsystem: "do.j3.openvoice", category: "CaptureTiming").notice("stop-request segment=\(segment) reason=\(reason, privacy: .public)")
        recordingSegment = nil
        onCaptureChanged(false)
        stopCapture()
    }

    private func finishOrWait() {
        guard isActive, !isRecording else { return }
        guard transcript.finished else {
            armTimeout()
            return
        }
        invalidateTimeout()
        isActive = false
        let error = transcript.error
        onFinish(Result(text: text, error: error, sendsReturn: sendOnFinish && error == nil && !text.isEmpty))
    }

    private func invalidateTimeout() {
        timeoutToken += 1
        watchdog?.cancel()
        watchdog = nil
    }

    private func armTimeout() {
        guard watchdog == nil else { return }
        let gen = generation
        let token = timeoutToken
        let sleep = self.sleep
        let timeout = self.timeout
        watchdog = Task { [weak self] in
            do { try Task.checkCancellation(); try await sleep(timeout) } catch { return }
            guard let self, self.isActive, self.generation == gen,
                  self.timeoutToken == token, !self.isRecording else { return }
            self.cancel("识别超时")
        }
    }
}
