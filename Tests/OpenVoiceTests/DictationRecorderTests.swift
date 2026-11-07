import AVFoundation
import XCTest
@testable import OpenVoice

final class DictationRecorderTests: XCTestCase {
    private final class StartupProbe: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var returned = false
        private var stopped = 0
        private var ready = 0
        func noteReturned() { lock.lock(); returned = true; lock.unlock() }
        func noteStopped() { lock.lock(); stopped += 1; lock.unlock() }
        func noteReady() { lock.lock(); ready += 1; lock.unlock() }
        var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
        var stops: Int { lock.lock(); defer { lock.unlock() }; return stopped }
        var readies: Int { lock.lock(); defer { lock.unlock() }; return ready }
    }

    private final class SlowInput: RecordingSource {
        let probe: StartupProbe
        var onLevel: ((Float) -> Void)?
        var output: AsyncStream<[Int16]>.Continuation?
        init(_ probe: StartupProbe) { self.probe = probe }
        func start() throws -> AsyncStream<[Int16]> {
            probe.entered.signal()
            probe.release.wait()
            let (stream, output) = AsyncStream<[Int16]>.makeStream()
            self.output = output
            output.yield([101])
            return stream
        }
        func stop() { probe.noteStopped(); output?.yield([102]); output?.finish(); output = nil }
    }

    func testSlowVoiceInitializationReturnsWithoutHoldingTheShortcutCallback() async throws {
        let suite = "OpenVoice-Echo-Nonblocking-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.suppressPlaybackKey)
        let probe = StartupProbe()
        let recorder = Recorder(defaults: defaults) { _, _ in SlowInput(probe) }
        let work = Task.detached {
            let stream = try recorder.start()
            probe.noteReturned()
            return stream
        }
        // Hardware remains blocked until after this assertion. No wall-clock
        // benchmark can make a synchronous hardware start pass this contract.
        probe.entered.wait()
        for _ in 0..<100 where !probe.hasReturned {
            try await Task.sleep(for: .milliseconds(2))
        }
        let returnedBeforeReady = probe.hasReturned
        probe.release.signal()
        let stream = try await work.value
        recorder.stop()
        for await _ in stream {}
        XCTAssertTrue(returnedBeforeReady, "Audio initialization must not block the key callback")
    }

    func testStoppingDuringPreparationOrdersCleanupBeforeNextRawCaptureAndRejectsOldReady() async throws {
        let suite = "OpenVoice-Echo-StartupOwnership-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.suppressPlaybackKey)
        let first = StartupProbe(), next = StartupProbe(), ready = StartupProbe()
        let recorder = Recorder(defaults: defaults) { suppress, _ in SlowInput(suppress ? first : next) }
        recorder.onReady = { ready.noteReady() }
        let oldStream = try recorder.start()
        first.entered.wait()
        XCTAssertTrue(recorder.isPreparing)
        recorder.stop()
        defaults.set(false, forKey: Recorder.suppressPlaybackKey)
        let newStream = try recorder.start()
        XCTAssertEqual(next.entered.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(ready.readies, 0)
        first.release.signal()
        next.entered.wait()
        XCTAssertEqual(first.stops, 1, "Old hardware must close before the next source starts")
        XCTAssertEqual(ready.readies, 0, "Cancelled initialization cannot report recording ready")
        next.release.signal()
        try await waitUntil { !recorder.isPreparing && ready.readies == 1 }
        recorder.stop()
        var old: [[Int16]] = [], new: [[Int16]] = []
        for await frame in oldStream { old.append(frame) }
        for await frame in newStream { new.append(frame) }
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new, [[101], [102]])
        XCTAssertEqual(next.stops, 1)
    }

    private final class Input: RecordingSource {
        var onLevel: ((Float) -> Void)?
        var output: AsyncStream<[Int16]>.Continuation?
        var stops = 0
        var fails = false
        func start() throws -> AsyncStream<[Int16]> {
            let (stream, output) = AsyncStream<[Int16]>.makeStream()
            self.output = output
            if fails { throw ASRError("设备不支持") }
            output.yield([101])
            onLevel?(0.5)
            return stream
        }
        func stop() {
            stops += 1
            output?.yield([102])
            output?.finish()
            output = nil
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Recording did not become ready")
        throw ASRError("录音准备超时")
    }

    func testSettingIsOffByDefaultAndSnapshotsEachRecordingWithoutInterruptingIt() async throws {
        let suite = "OpenVoice-EchoCapture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var modes: [Bool] = [], devices: [String] = [], inputs: [Input] = []
        let recorder = Recorder(defaults: defaults) { mode, uid in
            modes.append(mode); devices.append(uid)
            let input = Input()
            inputs.append(input)
            return input
        }
        var levels: [Float] = []
        recorder.onLevel = { levels.append($0) }
        let first = try recorder.start()
        try await waitUntil { !recorder.isPreparing }
        defaults.set(true, forKey: Recorder.suppressPlaybackKey)
        defaults.set("chosen-device", forKey: "micUID")
        XCTAssertThrowsError(try recorder.start())
        XCTAssertEqual(inputs.count, 1, "Changing settings cannot open a second capture")
        XCTAssertEqual(inputs[0].stops, 0)
        recorder.stop()
        recorder.stop()
        var firstFrames: [[Int16]] = []
        for await frame in first { firstFrames.append(frame) }
        XCTAssertEqual(firstFrames, [[101], [102]])
        XCTAssertEqual(inputs[0].stops, 1)

        let second = try recorder.start()
        defaults.set(false, forKey: Recorder.suppressPlaybackKey)
        try await waitUntil { !recorder.isPreparing }
        recorder.stop()
        let third = try recorder.start()
        try await waitUntil { !recorder.isPreparing }
        recorder.stop()
        for await _ in second {}
        for await _ in third {}
        XCTAssertEqual(modes, [false, true, false])
        XCTAssertEqual(devices, ["", "chosen-device", "chosen-device"])
        XCTAssertEqual(levels, [0.5, 0.5, 0.5])
    }

    func testFailedEchoStartCleansUpAndCanRetryWithoutSilentlyUsingRawAudio() async throws {
        let suite = "OpenVoice-EchoFailure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.suppressPlaybackKey)
        let failed = Input(), next = Input()
        failed.fails = true
        var attempts = 0
        let recorder = Recorder(defaults: defaults) { mode, _ in
            XCTAssertTrue(mode)
            attempts += 1
            return attempts == 1 ? failed : next
        }
        let failedStream = try recorder.start()
        let failure = recorder.failureSnapshot
        for await _ in failedStream {}
        XCTAssertEqual(failure(), "设备不支持")
        XCTAssertEqual(failed.stops, 1)
        XCTAssertNil(failed.output)
        XCTAssertEqual(attempts, 1)
        recorder.stop()
        let stream = try recorder.start()
        try await waitUntil { !recorder.isPreparing }
        recorder.stop()
        var frames: [[Int16]] = []
        for await frame in stream { frames.append(frame) }
        XCTAssertEqual(frames, [[101], [102]])
        XCTAssertEqual(next.stops, 1)
    }

    private func buffer(_ values: [Int16]) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: FrameConverter.format,
                                                   frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer {
            buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: $0.count)
        }
        return buffer
    }

    func testProcessedFramesKeepFullTailAndLateTapCannotWriteIntoNextRun() async throws {
        let first = try VoiceProcessingFrames(format: FrameConverter.format)
        let second = try VoiceProcessingFrames(format: FrameConverter.format)
        first.push(try buffer(Array(repeating: 101, count: 320) + [102, 103, 104]))
        first.finish()
        first.finish()
        // Simulate an already queued tap callback after engine teardown/restart.
        first.push(try buffer(Array(repeating: 999, count: 320)))
        second.push(try buffer(Array(repeating: 201, count: 320)))
        second.finish()
        var a: [[Int16]] = [], b: [[Int16]] = []
        for await frame in first.stream { a.append(frame) }
        for await frame in second.stream { b.append(frame) }
        XCTAssertEqual(a, [Array(repeating: 101, count: 320),
                           [102, 103, 104] + Array(repeating: 0, count: 317)])
        XCTAssertEqual(b, [Array(repeating: 201, count: 320)])
    }

    func testProcessedNativeFloatAudioConvertsToMono16kFrames() async throws {
        try await verifyFloatAudio(channels: 2)
    }

    func testProcessedAggregateAudioRetainsAudibleSamplesInsteadOfSilence() async throws {
        try await verifyFloatAudio(channels: 9)
    }

    private func verifyFloatAudio(channels: AVAudioChannelCount) async throws {
        // Aggregate devices can expose channel counts with no standard speaker
        // layout; the common-format convenience initializer rejects nine channels.
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout))
        let sink = try VoiceProcessingFrames(format: format)
        let block = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        block.frameLength = 960
        for channel in 0..<Int(channels) {
            block.floatChannelData![channel].initialize(repeating: 0.25, count: 960)
        }
        for _ in 0..<5 { sink.push(block) }
        sink.finish()
        var frames: [[Int16]] = []
        for await frame in sink.stream { frames.append(frame) }
        XCTAssertGreaterThanOrEqual(frames.count, 4)
        XCTAssertLessThanOrEqual(frames.count, 5)
        XCTAssertTrue(frames.allSatisfy { $0.count == 320 })
        XCTAssertTrue(frames.flatMap { $0 }.contains { $0 > 7000 && $0 < 9000 })
    }
}
