import Foundation

/// A cancellable race that doesn't wait for an uncooperative network request on timeout.
/// Each attempt owns its engine, so a late callback cannot change another attempt's result.
private final class MeetingRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        let ready = lock.withLock { () -> Result<T, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func add(_ task: Task<Void, Never>) {
        let done = lock.withLock { () -> Bool in
            if result != nil { return true }
            tasks.append(task)
            return false
        }
        if done { task.cancel() }
    }

    func resolve(_ value: Result<T, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<T, Error>?, [Task<Void, Never>])? in
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil; tasks = [] }
            return (continuation, tasks)
        }
        guard let pending else { return }
        pending.0?.resume(with: value)
        pending.1.forEach { $0.cancel() }
    }
}

func meetingWithTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    let race = MeetingRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.attach(continuation)
            race.add(Task {
                do {
                    try Task.checkCancellation()
                    race.resolve(.success(try await operation()))
                }
                catch { race.resolve(.failure(error)) }
            })
            race.add(Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    race.resolve(.failure(ASRError("转写响应超时")))
                } catch { }
            })
        }
    } onCancel: {
        race.resolve(.failure(CancellationError()))
    }
}

actor MeetingPipeline {
    typealias EngineFactory = (Channel) -> ASREngine
    private let archive: MeetingArchive
    private let channels: [Channel]
    private let factory: EngineFactory
    private let onUpdate: (MeetingRecord) -> Void
    private let attemptTimeout: TimeInterval
    private var record: MeetingRecord
    private var segmenter = MeetingSegmenter()
    private var active: [Int: Task<Void, Never>] = [:]
    private var feeds: [Int: AsyncStream<[Int16]>.Continuation] = [:]
    private var tokens: [Int: UUID] = [:]
    private var retryAfter: [Int: Date] = [:]
    private var unhealthy: [Channel: Date] = [:]
    private var preferred: Channel
    private var offlineInUse = false
    private var suspended = false
    private var lastCheckpoint = Date.distantPast
    private var lastUIUpdate = Date.distantPast
    private var pendingUIUpdate: Task<Void, Never>?

    init(archive: MeetingArchive, record: MeetingRecord = MeetingRecord(startedAt: Date()),
         channels: [Channel], attemptTimeout: TimeInterval = 55,
         factory: @escaping EngineFactory = MeetingPipeline.makeEngine,
         onUpdate: @escaping (MeetingRecord) -> Void) throws {
        guard let first = channels.first else { throw ASRError("没有可用的会议转写渠道") }
        self.archive = archive
        self.record = record
        self.channels = channels
        preferred = first
        self.factory = factory
        self.onUpdate = onUpdate
        self.attemptTimeout = attemptTimeout
        try archive.save(record)
    }

    static func makeEngine(_ channel: Channel) -> ASREngine {
        switch channel {
        case .doubao, .all: DoubaoEngine(requireFinalResult: true)
        case .wetype: WeTypeEngine()
        case .qwen: QwenEngine(requireFinalResult: true)
        case .offline: OfflineEngine(dedicatedWorker: true)
        }
    }

    func snapshot() -> MeetingRecord { record }

    func append(_ frame: [Int16]) throws {
        guard !suspended, !record.captureEnded, record.capturePaused != true else { return }
        // Disk failure stops capture and is surfaced; never pretend unsaved audio is protected.
        try archive.append(frame)
        let startsSegment = record.segments.last?.sealed != false
        if startsSegment {
            record.segments.append(MeetingSegment(id: record.segments.count, startFrame: archive.frameCount - 1,
                                                  endFrame: archive.frameCount - 1))
        }
        let i = record.segments.count - 1
        record.frameCount = archive.frameCount
        record.segments[i].endFrame = archive.frameCount
        let level = Recorder.level(frame)
        if level > 0.15 { record.segments[i].hasSignal = true }
        feeds[i]?.yield(frame)
        if segmenter.push(level: level) {
            record.segments[i].sealed = true
            feeds.removeValue(forKey: i)?.finish()
            segmenter.reset()
            try checkpoint()
        } else if Date().timeIntervalSince(lastCheckpoint) > 3 {
            try checkpoint()
        } else {
            emitUpdate()
        }
        // Scanning the history on all 50 audio frames/second grows with meeting length.
        // Work only becomes runnable when a segment is added, a task finishes, or a retry fires.
        if startsSegment { pump() }
    }

    func pauseCapture(at date: Date = Date(), error: String = "") throws {
        guard !record.captureEnded else { return }
        if record.capturePaused == true {
            record.captureError = error
            try checkpoint()
            return
        }
        sealCurrentSegment()
        record.capturePaused = true
        record.captureError = error
        if record.pauses == nil { record.pauses = [] }
        let pause = MeetingRecord.Pause(frame: record.frameCount, beganAt: date)
        record.pauses?.append(pause)
        try checkpoint()
        pump()
    }

    func resumeCapture(at date: Date = Date()) throws {
        guard !suspended, !record.captureEnded, record.capturePaused == true else { throw ASRError("当前会议无法恢复收音") }
        record.capturePaused = false
        record.captureError = ""
        if let i = record.pauses?.indices.last { record.pauses?[i].endedAt = date }
        try checkpoint()
    }

    private func sealCurrentSegment() {
        if let i = record.segments.indices.last, !record.segments[i].sealed {
            record.segments[i].sealed = true
            feeds.removeValue(forKey: i)?.finish()
        }
        segmenter.reset()
    }

    func finishCapture(error: String = "") throws {
        record.captureEnded = true
        record.captureError = error
        sealCurrentSegment()
        try checkpoint()
        pump()
    }

    func retryPending(force: Bool = false) {
        guard !suspended else { return }
        if force { retryAfter = [:]; unhealthy = [:] }
        pump()
    }

    func suspend() throws {
        suspended = true
        pendingUIUpdate?.cancel()
        pendingUIUpdate = nil
        for task in active.values { task.cancel() }
        active = [:]
        for feed in feeds.values { feed.finish() }
        feeds = [:]
        tokens = [:]
        for i in record.segments.indices where record.segments[i].state != .complete {
            record.segments[i].state = .pending
        }
        try checkpoint()
    }

    func exportWAV(to url: URL) throws { try archive.exportWAV(to: url) }

    private func checkpoint() throws {
        try archive.save(record)
        lastCheckpoint = Date()
        emitUpdate(immediately: true)
    }

    private func publish() {
        // Audio capture checks persistence errors on its next frame. Also expose errors after stop.
        do { try checkpoint() }
        catch {
            record.captureError = "保存会议记录失败：\(error.localizedDescription)"
            emitUpdate(immediately: true)
        }
    }

    private func pump() {
        guard !suspended else { return }
        // Bounded concurrency lets the next live segment start while the prior one finalizes/replays.
        for segment in record.segments where active.count < 3 {
            guard active[segment.id] == nil, segment.state != .complete,
                  retryAfter[segment.id, default: .distantPast] <= Date() else { continue }
            active[segment.id] = Task { await transcribe(segment.id) }
        }
    }

    private func transcribe(_ id: Int) async {
        let order = channels.sorted { a, b in
            if a == b { return false }
            let aCooling = unhealthy[a, default: .distantPast] > Date()
            let bCooling = unhealthy[b, default: .distantPast] > Date()
            if aCooling != bCooling { return !aCooling }
            if a == preferred { return true }
            if b == preferred { return false }
            return (channels.firstIndex(of: a) ?? 0) < (channels.firstIndex(of: b) ?? 0)
        }
        defer { active[id] = nil; pump() }
        for (attempt, channel) in order.enumerated() {
            guard !Task.isCancelled, !suspended else { return }
            if channel == .offline {
                // The local model is ~1 GB. Reuse a single slot rather than loading three copies.
                while offlineInUse {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard !suspended else { return }
                }
                offlineInUse = true
            }
            defer { if channel == .offline { offlineInUse = false } }
            let token = UUID()
            tokens[id] = token
            record.segments[id].state = attempt == 0 ? .transcribing : .retrying
            record.segments[id].provider = channel.title
            // A partial is provisional, never appended to the final transcript on fallback.
            record.segments[id].text = ""
            publish()
            do {
                let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
                for frame in try archive.frames(from: record.segments[id].startFrame, to: record.segments[id].endFrame) {
                    continuation.yield(frame)
                }
                if record.segments[id].sealed { continuation.finish() }
                else { feeds[id] = continuation }
                let engine = factory(channel)
                let text = try await meetingWithTimeout(seconds: attemptTimeout) {
                    try await engine.run(audio: stream) { text in
                        self.receivePartial(id, token: token, text: text)
                    }
                }
                try Task.checkCancellation()
                guard tokens[id] == token, !suspended else { return }
                guard record.segments[id].sealed else { throw ASRError("渠道提前结束，正在重放完整片段") }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !record.segments[id].hasSignal else {
                    throw ASRError("有音频但渠道未返回文字")
                }
                record.segments[id].text = text
                record.segments[id].state = .complete
                record.segments[id].error = ""
                preferred = channel
                unhealthy[channel] = nil
                tokens[id] = nil
                publish()
                return
            } catch is CancellationError {
                if Task.isCancelled || suspended { return }
                record.segments[id].error = "渠道取消了转写，正在切换"
            } catch {
                record.segments[id].error = "\(channel.title)：\(error.localizedDescription)"
            }
            tokens[id] = nil
            feeds.removeValue(forKey: id)?.finish()
            unhealthy[channel] = Date().addingTimeInterval(60)
        }
        guard !suspended, !Task.isCancelled else { return }
        record.segments[id].state = .pending
        retryAfter[id] = Date().addingTimeInterval(30)
        publish()
    }

    private func partial(_ id: Int, token: UUID, text: String) {
        guard tokens[id] == token, !suspended, record.segments[id].text != text else { return }
        record.segments[id].text = text
        // UI updates are cheap; manifests are checkpointed by the capture loop / final result.
        emitUpdate()
    }

    private func emitUpdate(immediately: Bool = false) {
        let remaining = 0.25 - Date().timeIntervalSince(lastUIUpdate)
        if immediately || remaining <= 0 {
            pendingUIUpdate?.cancel()
            pendingUIUpdate = nil
            lastUIUpdate = Date()
            record.updateSequence = (record.updateSequence ?? 0) + 1
            onUpdate(record)
        } else if pendingUIUpdate == nil {
            pendingUIUpdate = Task {
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self.emitUpdate(immediately: true)
            }
        }
    }

    private nonisolated func receivePartial(_ id: Int, token: UUID, text: String) {
        Task { await partial(id, token: token, text: text) }
    }
}
