import Foundation

/// Multi-channel counterpart of upstream controller.rs::Pick. View confirmation is
/// a request, never permission to paste an unfinished or failed row.
@MainActor
final class DictationPicker {
    enum Phase { case listening, waiting, final, error, skipped }
    struct Row {
        let channel: Channel
        var text = ""
        var phase: Phase = .listening
        var error: String?
        var status: String {
            switch phase {
            case .listening: "识别中"
            case .waiting: "等待定稿"
            case .final: "完成"
            case .error: error ?? "没有识别到内容"
            case .skipped: "跳过（未下载）"
            }
        }
    }
    struct Choice {
        let channel: Channel
        let text: String
        let sendsReturn: Bool
    }
    private struct Key: Hashable { let channel: Channel; let segment: Int }
    private let startCapture: () throws -> AsyncStream<[Int16]>
    private let stopCapture: () -> Void
    private let pool: DictationEnginePool
    private let defaults: UserDefaults
    private let sleep: (TimeInterval) async throws -> Void
    private var transcripts: [Channel: DictationTranscript] = [:]
    private var tasks: [Key: Task<Void, Never>] = [:]
    private var fanouts: [Task<Void, Never>] = []
    private var watchdog: Task<Void, Never>?
    private var generation = 0
    private var timeoutToken = 0
    private var userPicked = false
    private(set) var sendsReturn = false
    private(set) var isActive = false
    private(set) var isRecording = false
    private(set) var selected = 0
    private(set) var choosePending = false
    private(set) var rows: [Row] = []

    var onUpdate: ([Row], Int) -> Void = { _, _ in }
    var onChoice: (Choice) -> Void = { _ in }
    var onCancel: (String, String?) -> Void = { _, _ in }
    var onCaptureChanged: (Bool) -> Void = { _ in }
    var onSpeech: () -> Void = {}
    var onInvalidChoice: () -> Void = {}

    init(startCapture: @escaping () throws -> AsyncStream<[Int16]>, stopCapture: @escaping () -> Void,
         pool: DictationEnginePool, defaults: UserDefaults = .standard,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.pool = pool
        self.defaults = defaults
        self.sleep = sleep
    }

    @discardableResult
    func start(channels: [Channel], skipped: Set<Channel> = [], sendsReturn: Bool = false) throws -> Bool {
        guard !isRecording else { return false }
        let audio = try startCapture()
        invalidateTimeout()
        if !isActive {
            generation += 1
            let counts = defaults.dictionary(forKey: "pickCounts") as? [String: Int] ?? [:]
            rows = channels.enumerated().sorted {
                let a = counts[$0.element.rawValue] ?? 0, b = counts[$1.element.rawValue] ?? 0
                return a == b ? $0.offset < $1.offset : a > b
            }.map { Row(channel: $0.element, phase: skipped.contains($0.element) ? .skipped : .listening) }
            transcripts = [:]
            selected = rows.firstIndex { $0.channel.rawValue == defaults.string(forKey: "lastPick") && $0.phase != .skipped } ?? 0
            userPicked = rows.indices.contains(selected) && rows[selected].channel.rawValue == defaults.string(forKey: "lastPick")
            self.sendsReturn = false
            isActive = true
        }
        self.sendsReturn = self.sendsReturn || sendsReturn
        choosePending = false
        isRecording = true
        onCaptureChanged(true)
        let gen = generation
        var outputs: [AsyncStream<[Int16]>.Continuation] = []
        for i in rows.indices where rows[i].phase != .skipped {
            let channel = rows[i].channel
            var transcript = transcripts[channel] ?? DictationTranscript()
            let segment = transcript.begin()
            transcripts[channel] = transcript
            rows[i].phase = .listening
            rows[i].text = transcript.text
            rows[i].error = nil
            let (stream, output) = AsyncStream<[Int16]>.makeStream()
            outputs.append(output)
            let lease = pool.take(channel)
            let key = Key(channel: channel, segment: segment)
            let pool = self.pool
            tasks[key] = Task { [weak self] in
                do {
                    await lease.ready()
                    try Task.checkCancellation()
                    let text = try await lease.engine.run(audio: stream) { [weak self] text in
                        DispatchQueue.main.async { [weak self] in self?.partial(text, key: key, gen: gen) }
                    }
                    if !Task.isCancelled { pool.reuse(lease.engine, channel: channel) }
                    DispatchQueue.main.async { [weak self] in self?.complete(text, error: nil, key: key, gen: gen) }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { [weak self] in self?.complete("", error: message, key: key, gen: gen) }
                }
            }
        }
        let targets = outputs
        fanouts.append(Task {
            for await frame in audio { for output in targets { output.yield(frame) } }
            for output in targets { output.finish() }
        })
        publish()
        return true
    }

    func end() {
        guard isRecording else { return }
        isRecording = false
        onCaptureChanged(false)
        stopCapture()
        for i in rows.indices where rows[i].phase == .listening { rows[i].phase = .waiting }
        armTimeout()
        publish()
        maybeChoose()
    }

    func select(_ channel: Channel) {
        guard isActive, let i = rows.firstIndex(where: { $0.channel == channel }) else { return }
        selected = i
        userPicked = true
        publish()
    }
    func move(_ delta: Int) {
        guard isActive, !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
        userPicked = true
        publish()
    }
    func digit(_ digit: Int) {
        let i = digit - 1
        guard rows.indices.contains(i) else { return }
        if selected == i { choose(rows[i].channel) }
        else { select(rows[i].channel) }
    }
    func confirm() { if rows.indices.contains(selected) { choose(rows[selected].channel) } }
    func choose(_ channel: Channel) {
        guard isActive, let i = rows.firstIndex(where: { $0.channel == channel }) else { return }
        selected = i
        userPicked = true
        switch rows[i].phase {
        case .listening, .waiting:
            choosePending = true
            end()
            publish()
        case .final: commit(i)
        case .error, .skipped:
            onInvalidChoice()
            publish()
        }
    }

    func cancel(_ message: String? = nil) {
        guard isActive else { return }
        let text = rows.indices.contains(selected) ? rows[selected].text : ""
        reset()
        onCancel(text, message)
    }

    private func partial(_ text: String, key: Key, gen: Int) {
        guard isActive, generation == gen, var transcript = transcripts[key.channel],
              let changed = transcript.update(key.segment, text: text),
              let i = rows.firstIndex(where: { $0.channel == key.channel }) else { return }
        transcripts[key.channel] = transcript
        rows[i].text = transcript.text
        if changed { onSpeech() }
        publish()
    }
    private func complete(_ text: String, error: String?, key: Key, gen: Int) {
        guard isActive, generation == gen, var transcript = transcripts[key.channel],
              transcript.finish(key.segment, text: text, error: error, keepPartial: false),
              let i = rows.firstIndex(where: { $0.channel == key.channel }) else { return }
        transcripts[key.channel] = transcript
        tasks[key] = nil
        rows[i].text = transcript.text
        rows[i].error = transcript.error
        if transcript.finished { rows[i].phase = transcript.text.isEmpty ? .error : .final }
        if rows[i].phase == .final, rows.indices.contains(selected) {
            let current = rows[selected].phase
            if (!userPicked || current == .error || current == .skipped), current != .final { selected = i }
        }
        if rows.allSatisfy({ $0.phase == .final || $0.phase == .error || $0.phase == .skipped }) { invalidateTimeout() }
        publish()
        maybeChoose()
    }

    private func maybeChoose() {
        guard isActive, rows.indices.contains(selected) else { return }
        if sendsReturn, !isRecording, let i = rows.indices.first(where: { rows[$0].phase == .final && rows[$0].error == nil }) {
            commit(i)
            return
        }
        if sendsReturn, !isRecording,
           rows.allSatisfy({ $0.phase == .final || $0.phase == .error || $0.phase == .skipped }) {
            cancel("没有可发送的完整识别结果")
            return
        }
        guard choosePending else { return }
        if rows[selected].phase == .error || rows[selected].phase == .skipped,
           let i = rows.indices.first(where: { rows[$0].phase == .final }) { selected = i }
        if rows[selected].phase == .final { commit(selected) }
        else if rows.allSatisfy({ $0.phase == .error || $0.phase == .skipped }) { choosePending = false; publish() }
    }
    private func commit(_ i: Int) {
        guard rows.indices.contains(i), rows[i].phase == .final else { return }
        let row = rows[i]
        let choice = Choice(channel: row.channel, text: row.text, sendsReturn: sendsReturn && row.error == nil)
        defaults.set(row.channel.rawValue, forKey: "lastPick")
        var counts = defaults.dictionary(forKey: "pickCounts") as? [String: Int] ?? [:]
        counts[row.channel.rawValue, default: 0] += 1
        defaults.set(counts, forKey: "pickCounts")
        reset()
        onChoice(choice)
    }
    private func reset() {
        isActive = false
        generation += 1
        invalidateTimeout()
        if isRecording { isRecording = false; onCaptureChanged(false); stopCapture() }
        for task in tasks.values { task.cancel() }
        tasks = [:]
        for task in fanouts { task.cancel() }
        fanouts = []
        choosePending = false
    }
    private func publish() { onUpdate(rows, selected) }
    private func invalidateTimeout() { timeoutToken += 1; watchdog?.cancel(); watchdog = nil }
    private func armTimeout() {
        invalidateTimeout()
        guard rows.contains(where: { $0.phase == .waiting }) else { return }
        let gen = generation, token = timeoutToken
        let sleep = self.sleep
        watchdog = Task { [weak self] in
            do { try Task.checkCancellation(); try await sleep(15) } catch { return }
            guard let self, self.isActive, self.generation == gen, self.timeoutToken == token, !self.isRecording else { return }
            self.cancel("识别超时")
        }
    }
}
