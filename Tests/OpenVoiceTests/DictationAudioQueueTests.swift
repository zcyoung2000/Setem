import Foundation
import CoreAudio
import XCTest
@testable import OpenVoice

private final class DelayedAudioInput: AudioQueueInput {
    private var callbackQueue: DispatchQueue?
    private var receive: ((UnsafeBufferPointer<Int16>) -> Void)?
    private var failed: ((Error) -> Void)?
    var running = true
    var transportType: UInt32? = kAudioDeviceTransportTypeBluetooth
    var stops: [Bool] = []
    var disposed = false
    var startError: Error?
    func open(microphoneUID: String, callbackQueue: DispatchQueue,
              receive: @escaping (UnsafeBufferPointer<Int16>) -> Void,
              failed: @escaping (Error) -> Void) throws {
        self.callbackQueue = callbackQueue
        self.receive = receive
        self.failed = failed
    }
    func start() throws { if let startError { throw startError } }
    func stop(immediately: Bool) throws { stops.append(immediately); if immediately { running = false } }
    func isRunning() throws -> Bool { running }
    func dispose() { disposed = true }
    func send(_ value: Int16, count: Int = 320) {
        callbackQueue?.sync { [Int16](repeating: value, count: count).withUnsafeBufferPointer { receive?($0) } }
    }
    func fail() { failed?(ASRError("蓝牙设备已断开")) }
}

@MainActor
private final class AudioTailEngine: ASREngine {
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        var text = ""
        for await frame in audio {
            text += frame[0] == 101 ? "开头" : "和结尾。"
            partial(text)
        }
        return text
    }
}

@MainActor
final class DictationAudioQueueTests: XCTestCase {
    func testStoppedCallbackFollowsNativeDisposalAndPreservesTheTail() async throws {
        let input = DelayedAudioInput()
        let source = AudioQueueSource(microphoneUID: "", input: input)
        let stream = try source.start()
        var stopped = false
        input.send(101)
        source.stop {
            XCTAssertTrue(input.disposed)
            stopped = true
        }
        XCTAssertFalse(stopped)
        input.send(102, count: 37)
        input.running = false
        var values: [Int16] = []
        for await frame in stream { values.append(frame[0]) }
        XCTAssertTrue(stopped)
        XCTAssertEqual(values, [101, 102])
    }

    func testNonBluetoothInputsFinishSynchronouslyAndKeepTheExactTail() async throws {
        for transport: UInt32? in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                                   kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeVirtual,
                                   kAudioDeviceTransportTypeUnknown, nil] {
            let input = DelayedAudioInput()
            input.transportType = transport
            let source = AudioQueueSource(microphoneUID: "", input: input)
            let stream = try source.start()
            input.send(101)
            input.send(102, count: 37)
            source.stop()
            XCTAssertTrue(input.disposed, "Non-Bluetooth input must finish within stop(), without waiting for a drain task")
            XCTAssertEqual(input.stops, [true])
            var frames: [[Int16]] = []
            for await frame in stream { frames.append(frame) }
            XCTAssertEqual(frames, [[Int16](repeating: 101, count: 320),
                                   [Int16](repeating: 102, count: 37) + [Int16](repeating: 0, count: 283)])
        }
    }

    func testDrainFollowsActualInputAtStopIncludingBluetoothLE() async throws {
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth,
                          kAudioDeviceTransportTypeBluetoothLE] {
            let input = DelayedAudioInput()
            input.transportType = transport == kAudioDeviceTransportTypeBuiltIn
                ? kAudioDeviceTransportTypeBluetooth : kAudioDeviceTransportTypeBuiltIn
            let source = AudioQueueSource(microphoneUID: "", input: input)
            let stream = try source.start()
            // Follow a changed default input rather than caching the initial route
            // or inferring capture from the connected playback headphones.
            input.transportType = transport
            input.send(101)
            source.stop()
            XCTAssertEqual(input.stops, [transport == kAudioDeviceTransportTypeBuiltIn])
            input.running = false
            var frames: [[Int16]] = []
            for await frame in stream { frames.append(frame) }
            XCTAssertEqual(frames, [[Int16](repeating: 101, count: 320)])
        }
    }

    func testDelayedBluetoothTailReachesExactFinalAfterKeyUp() async throws {
        let suite = "OpenVoice-AudioTail-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = DelayedAudioInput()
        let recorder = Recorder(defaults: defaults) { _ in AudioQueueSource(microphoneUID: "", input: input) }
        let capture = DictationCapture(start: recorder.start, stop: recorder.stop)
        let model = DictationSession(startCapture: capture.take, stopCapture: capture.stop,
                                     captureFailure: { recorder.failureSnapshot }, makeEngine: { _ in AudioTailEngine() })
        defer { model.cancel() }
        var results: [DictationSession.Result] = []
        model.onFinish = { results.append($0) }
        try model.start(channel: .wetype, sendsReturn: true)
        input.send(101)
        try await parityEventually { model.text == "开头" }
        model.end()
        XCTAssertEqual(input.stops, [false])
        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(results.isEmpty, "ASR must wait until the Bluetooth tail has drained")
        input.send(102, count: 37)
        input.running = false
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results, [.init(text: "开头和结尾。", error: nil, sendsReturn: true)])
        XCTAssertTrue(input.disposed)
    }

    func testOldDrainCannotCloseOrContaminateNextRecording() async throws {
        let firstInput = DelayedAudioInput(), secondInput = DelayedAudioInput()
        let first = AudioQueueSource(microphoneUID: "", input: firstInput)
        let second = AudioQueueSource(microphoneUID: "", input: secondInput)
        var oldLevels: [Float] = []
        first.onLevel = { oldLevels.append($0) }
        let old = try first.start()
        firstInput.send(101)
        first.stop()
        first.stop()
        let new = try second.start()
        secondInput.send(201)
        firstInput.send(102)
        firstInput.running = false
        var oldFrames: [[Int16]] = []
        for await frame in old { oldFrames.append(frame) }
        XCTAssertEqual(oldFrames, [[Int16](repeating: 101, count: 320),
                                   [Int16](repeating: 102, count: 320)])
        XCTAssertEqual(oldLevels.count, 1, "Draining old audio must not update the next recording's meter")
        XCTAssertFalse(secondInput.disposed)
        XCTAssertTrue(secondInput.stops.isEmpty)
        secondInput.send(202)
        second.stop()
        secondInput.running = false
        var newFrames: [[Int16]] = []
        for await frame in new { newFrames.append(frame) }
        XCTAssertEqual(newFrames, [201, 202].map { [Int16](repeating: Int16($0), count: 320) })
    }

    func testStuckDrainIsBoundedAndReportsFailureWithoutDroppingPartialFrame() async throws {
        let input = DelayedAudioInput()
        let source = AudioQueueSource(microphoneUID: "", input: input, drainTimeout: 0.03)
        var errors: [String] = []
        source.onFailure = { errors.append($0.localizedDescription) }
        let stream = try source.start()
        input.send(102, count: 37)
        source.stop()
        var frames: [[Int16]] = []
        for await frame in stream { frames.append(frame) }
        XCTAssertEqual(frames, [[Int16](repeating: 102, count: 37) + [Int16](repeating: 0, count: 283)])
        XCTAssertEqual(errors, ["麦克风尾音读取超时，请检查蓝牙连接后重试"])
        XCTAssertTrue(input.disposed)
    }

    func testStartupFailureClosesQueueAndAllowsNewSource() throws {
        let input = DelayedAudioInput()
        input.startError = ASRError("麦克风启动失败")
        let source = AudioQueueSource(microphoneUID: "", input: input)
        XCTAssertThrowsError(try source.start())
        XCTAssertTrue(input.disposed)
    }
}
