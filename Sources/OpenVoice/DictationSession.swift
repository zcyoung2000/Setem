import Foundation

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
    private let makeEngine: (Channel) -> ASREngine
    private let enginePool: DictationEnginePool?
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
    var onSpeech: () -> Void = {}

    init(startCapture: @escaping () throws -> AsyncStream<[Int16]>,
         stopCapture: @escaping () -> Void,
         makeEngine: @escaping (Channel) -> ASREngine = DictationSession.makeEngine,
         enginePool: DictationEnginePool? = nil,
         timeout: TimeInterval = 15,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.makeEngine = makeEngine
        self.enginePool = enginePool
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

    /// A second start while finalizing appends a segment; it never cancels a pending final.
    @discardableResult
    func start(channel: Channel, sendsReturn: Bool = false) throws -> Bool {
        guard !isRecording else { return false }
        // Failure to open the next recording must leave the pending session and timer intact.
        let audio = try startCapture()
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
        let lease = pool?.take(channel)
        let engine = lease?.engine ?? makeEngine(channel)
        tasks[id] = Task { [weak self] in
            do {
                await lease?.ready()
                try Task.checkCancellation()
                let text = try await engine.run(audio: audio) { [weak self] partial in
                    DispatchQueue.main.async { [weak self] in self?.update(partial, id: id, generation: gen) }
                }
                if !Task.isCancelled { pool?.reuse(engine, channel: channel) }
                // Use the same FIFO as partials, including when a vendor returns/throws immediately.
                DispatchQueue.main.async { [weak self] in self?.complete(id: id, generation: gen, text: text, error: nil) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.complete(id: id, generation: gen, text: "", error: message) }
            }
        }
        return true
    }

    func end() {
        guard isRecording else { return }
        stopRecording()
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
        stopRecording()
        for task in oldTasks { task.cancel() }
        onCancel(kept, message)
    }

    private func update(_ text: String, id: Int, generation gen: Int) {
        guard isActive, generation == gen, !transcript.hasIdenticalPartial(id, text: text),
              let changed = transcript.update(id, text: text) else { return }
        if changed { onSpeech() }
        onUpdate(self.text)
    }

    private func complete(id: Int, generation gen: Int, text: String, error: String?) {
        guard isActive, generation == gen,
              transcript.finish(id, text: text, error: error, keepPartial: false) else { return }
        tasks[id] = nil
        // Finishing an older segment must not stop the recorder owned by a newer one.
        if transcript.finished { stopRecording() }
        onUpdate(self.text)
        finishOrWait()
    }

    private func stopRecording() {
        guard recordingSegment != nil else { return }
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
