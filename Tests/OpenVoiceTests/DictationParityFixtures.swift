import Foundation
import XCTest
@testable import OpenVoice

@MainActor
func parityEventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<1000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Dictation parity state not reached", file: file, line: line)
    throw ASRError("测试等待超时")
}

/// Observes source reads without inspecting the production pre-roll buffer.
@MainActor
final class ParityCapture {
    @MainActor final class Source {
        private var iterator: AsyncStream<[Int16]>.Iterator
        private let output: AsyncStream<[Int16]>.Continuation
        private(set) var requests = 0
        init() {
            let (stream, output) = AsyncStream<[Int16]>.makeStream()
            iterator = stream.makeAsyncIterator()
            self.output = output
        }
        func next() async -> [Int16]? {
            requests += 1
            var reading = iterator
            let frame = await reading.next()
            iterator = reading
            return frame
        }
        func send(_ value: Int16) { output.yield([Int16](repeating: value, count: 320)) }
        func finish() { output.finish() }
        var stream: AsyncStream<[Int16]> { AsyncStream(unfolding: { await self.next() }) }
    }
    private(set) var sources: [Source] = []
    private(set) var stops = 0
    private var current: Source?
    var startError: Error?
    var finishesOnStop = true
    var tail: Int16?
    func start() throws -> AsyncStream<[Int16]> {
        if let startError { throw startError }
        guard current == nil else { throw ASRError("录音尚未停止") }
        let source = Source()
        sources.append(source)
        current = source
        return source.stream
    }
    func send(_ value: Int16) { current?.send(value) }
    func stop() {
        stops += 1
        if let tail { current?.send(tail) }
        if finishesOnStop { current?.finish() }
        current = nil
    }
    func close() { sources.forEach { $0.finish() }; current = nil }
}

/// Cancellation deliberately does not resume replies or sleeps: late vendors and
/// already-enqueued timers must be fenced by the production state machine.
@MainActor
final class ParityClock {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private(set) var wakes = 0
    var pending: Int { waiters.count }
    func sleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
        wakes += 1
    }
    func advanceNext() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    func advance() { let old = waiters; waiters = []; old.forEach { $0.resume() } }
}

@MainActor
final class ParityEngine: ASREngine {
    @MainActor final class Round {
        let partial: (String) -> Void
        var reply: CheckedContinuation<String, Error>?
        var samples: [Int16] = []
        var ended = false
        var returned = false
        var wasCancelled = false
        init(_ partial: @escaping (String) -> Void) { self.partial = partial }
        func resolve(_ result: Result<String, Error>) {
            let continuation = reply; reply = nil; continuation?.resume(with: result)
        }
    }
    private(set) var rounds: [Round] = []
    private(set) var preparing = false
    var blocksPreparation = false
    private var preparation: CheckedContinuation<Void, Never>?
    func prepare() async {
        preparing = true
        if blocksPreparation { await withCheckedContinuation { preparation = $0 } }
        preparing = false
    }
    func prepared() { let old = preparation; preparation = nil; old?.resume() }
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        let round = Round(partial)
        rounds.append(round)
        let reader = Task {
            for await frame in audio { round.samples.append(frame[0]) }
            round.ended = true
        }
        defer { round.wasCancelled = Task.isCancelled; reader.cancel(); round.returned = true }
        return try await withCheckedThrowingContinuation { round.reply = $0 }
    }
    func close() {
        prepared()
        rounds.forEach { $0.resolve(.failure(CancellationError())) }
    }
}
