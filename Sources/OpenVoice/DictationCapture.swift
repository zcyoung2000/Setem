import Foundation

/// The hardware is started on key-down. Each run owns its frame gate, so a drained
/// tail from an earlier recording can never finish or write into the next stream.
@MainActor
final class DictationCapture {
    private final class Run {
        var frames: [[Int16]] = []
        var output: AsyncStream<[Int16]>.Continuation?
        var forwarding = false
        var discarded = false
        var pump: Task<Void, Never>?
    }
    private let startHardware: () throws -> AsyncStream<[Int16]>
    private let stopHardware: () -> Void
    private let preroll: Int
    private var current: Run?
    var isPrimed: Bool { current != nil && current?.forwarding == false }

    init(preroll: Int = 50, start: @escaping () throws -> AsyncStream<[Int16]>, stop: @escaping () -> Void) {
        self.preroll = preroll
        startHardware = start
        stopHardware = stop
    }

    func arm() throws {
        guard current == nil else { return }
        let source = try startHardware()
        let run = Run()
        current = run
        let limit = preroll
        run.pump = Task {
            for await frame in source {
                guard !run.discarded else { break }
                if run.forwarding { run.output?.yield(frame) }
                else {
                    run.frames.append(frame)
                    if run.frames.count > limit { run.frames.removeFirst(run.frames.count - limit) }
                }
            }
            run.output?.finish()
            run.output = nil
            run.frames = []
            run.pump = nil
        }
    }

    func take() throws -> AsyncStream<[Int16]> {
        try arm()
        guard let run = current, !run.forwarding else { throw ASRError("录音已开始") }
        let (stream, output) = AsyncStream<[Int16]>.makeStream()
        run.output = output
        run.forwarding = true
        for frame in run.frames { output.yield(frame) }
        run.frames = []
        return stream
    }

    func disarm() {
        guard let run = current, !run.forwarding else { return }
        current = nil
        run.discarded = true
        stopHardware()
        run.pump?.cancel()
    }

    func stop() {
        guard let run = current else { return }
        current = nil
        if !run.forwarding { run.discarded = true }
        // Recorder.stop finishes its input after yielding pending tail frames. Leave
        // this run's pump alive until those frames reach this run's output.
        stopHardware()
    }
}

@MainActor
final class DictationActivity {
    private let now: () -> TimeInterval
    private var listening = false
    private var heardVoice = false
    private var lastVoice: TimeInterval = 0

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    func start() { listening = true; heardVoice = false; lastVoice = now() }
    func stop() { listening = false }
    func speaking() {
        guard listening else { return }
        heardVoice = true
        lastVoice = now()
    }
    func shouldStop(level: Float, silence: TimeInterval, enabled: Bool = true) -> Bool {
        guard listening, enabled else { return false }
        if level > 0.3 { speaking(); return false }
        return now() - lastVoice > (heardVoice ? silence : 8)
    }
}
