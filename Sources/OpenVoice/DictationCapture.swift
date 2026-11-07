import Foundation

/// The hardware is started on key-down. Each run owns its frame gate, so a drained
/// tail from an earlier recording can never finish or write into the next stream.
@MainActor
final class DictationCapture {
    private final class Run {
        var frames = FIFOBuffer<[Int16]>()
        var output: AsyncStream<[Int16]>.Continuation?
        var forwarding = false
        var discarded = false
        var ended = false
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
                    while run.frames.count > limit { _ = run.frames.popFirst() }
                }
            }
            run.output?.finish()
            run.output = nil
            run.ended = true
            if run.discarded || run.forwarding { run.frames = FIFOBuffer() }
            run.pump = nil
        }
    }

    func take() throws -> AsyncStream<[Int16]> {
        try arm()
        guard let run = current, !run.forwarding else { throw ASRError("录音已开始") }
        let (stream, output) = AsyncStream<[Int16]>.makeStream()
        run.output = output
        run.forwarding = true
        while let frame = run.frames.popFirst() { output.yield(frame) }
        if run.ended { output.finish(); run.output = nil }
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
