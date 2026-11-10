import CoreAudio
import Foundation
import XCTest
@testable import OpenVoice

private final class RegressionNativeInput: AudioQueueInput {
    var transportType: UInt32? { kAudioDeviceTransportTypeBluetooth }
    var disposed = false
    var onDispose: (() -> Void)?
    private var callbackQueue: DispatchQueue?
    private var receive: ((UnsafeBufferPointer<Int16>) -> Void)?
    func open(microphoneUID: String, callbackQueue: DispatchQueue,
              receive: @escaping (UnsafeBufferPointer<Int16>) -> Void,
              failed: @escaping (Error) -> Void) throws {
        self.callbackQueue = callbackQueue
        self.receive = receive
    }
    func start() throws {}
    func stop(immediately: Bool) throws {}
    func isRunning() throws -> Bool { !disposed }
    func dispose() { disposed = true; onDispose?() }
    func send(_ marker: Int16, count: Int = 320) {
        callbackQueue?.sync { [Int16](repeating: marker, count: count).withUnsafeBufferPointer { receive?($0) } }
    }
}
private final class RegressionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
private final class RegressionTailTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    var count: Int { lock.withLock { pending.count } }
    func add(_ delay: TimeInterval, _ work: @escaping () -> Void) { lock.withLock { pending.append(work) } }
    func fire() {
        let actions = lock.withLock { let actions = pending; pending = []; return actions }
        actions.forEach { $0() }
    }
}
@MainActor
private final class RegressionTextEngine: ASREngine {
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        var text = ""
        for await frame in audio {
            if frame.first == 101 { text += "开头" }
            if frame.first == 102 { text += "和结尾。" }
            partial(text)
        }
        return text
    }
}
private final class RegressionComputerInput: RecordingSource {
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?
    private var output: AsyncStream<[Int16]>.Continuation?
    func send(_ marker: Int16) { output?.yield([Int16](repeating: marker, count: 320)) }
    func start() throws -> AsyncStream<[Int16]> {
        let (stream, output) = AsyncStream<[Int16]>.makeStream()
        self.output = output
        return stream
    }
    func stop() { output?.finish() }
}

@MainActor
final class DictationHeadsetRegressionTests: XCTestCase {
    private let airPods = Microphone(id: "review-airpods", name: "AirPods", deviceID: 123, transport: kAudioDeviceTransportTypeBluetooth)
    private let builtIn = Microphone(id: "review-built-in", name: "MacBook", deviceID: 124, transport: kAudioDeviceTransportTypeBuiltIn)

    private func defaults() throws -> UserDefaults {
        let name = "OpenVoice-ReviewProbe-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: MicrophonePreference.headsetKey)
        return defaults
    }

    func testRapidResumeMustNotRepeatThePreviousSegment() async throws {
        let native = RegressionNativeInput(), timers = RegressionTailTimers()
        let headset = HeadsetMicrophone(microphones: { [self.airPods] }, makeInput: { native },
                                        schedule: timers.add, lookback: 2, automaticallyMonitor: false)
        headset.setEnabled(true)
        headset.devicesChanged()
        native.send(1)
        headset.devicesChanged()
        let recorder = Recorder(defaults: try defaults()) { preference in
            RoutedRecordingSource(preference: preference, microphones: { [self.airPods] },
                                  makeSource: { try! XCTUnwrap(headset.tap(for: $0)) }, automaticallyMonitor: false)
        }
        let capture = DictationCapture(start: recorder.start, stop: recorder.stop)
        let session = DictationSession(startCapture: capture.take, stopCapture: capture.stop,
                                      captureFailure: { recorder.failureSnapshot }, makeEngine: { _ in RegressionTextEngine() })
        defer { session.cancel(); headset.setEnabled(false); timers.fire(); headset.devicesChanged() }
        var results: [DictationSession.Result] = []
        session.onFinish = { results.append($0) }
        try session.start(channel: .wetype)
        native.send(101)
        try await parityEventually { session.text == "开头" }
        session.end()
        try await parityEventually { timers.count == 1 }
        try session.start(channel: .wetype)
        native.send(102)
        session.end()
        try await parityEventually { timers.count == 2 }
        timers.fire()
        headset.devicesChanged()
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results.first?.text, "开头和结尾。", "Continuous speech must appear once when the user resumes during the previous tail")
    }

    func testSuspendingWithAnActiveTapMustReleaseTheMicrophone() throws {
        let native = RegressionNativeInput(), timers = RegressionTailTimers()
        let headset = HeadsetMicrophone(microphones: { [self.airPods] }, makeInput: { native },
                                        schedule: timers.add, automaticallyMonitor: false)
        headset.setEnabled(true)
        headset.devicesChanged()
        let tap = try XCTUnwrap(headset.tap(for: airPods))
        _ = try tap.start()
        defer { tap.stop(); headset.devicesChanged(); timers.fire(); headset.setEnabled(false); headset.devicesChanged() }
        headset.setSuspended(true)
        headset.devicesChanged()
        XCTAssertTrue(native.disposed, "Lock/sleep suspension must release the input even during a tap recording")
    }

    func testInputFailureMustArmAFinalDeadlineWithoutAnotherStopPress() async throws {
        let (audio, output) = AsyncStream<[Int16]>.makeStream()
        let engine = ParityEngine()
        let clock = ParityClock()
        var failure: String?
        var cancelledText: String?
        let pool = DictationEnginePool { _ in engine }
        let session = DictationSession(startCapture: { audio }, stopCapture: {}, captureFailure: { { failure } },
                                      enginePool: pool, replayPool: pool, failoverPolicy: .automatic, sleep: clock.sleep)
        session.onCancel = { text, _ in cancelledText = text }
        defer { session.cancel(); output.finish(); engine.close(); clock.advance() }
        try session.start(channel: .doubao)
        try await parityEventually { !engine.rounds.isEmpty }
        output.yield([101])
        try await parityEventually { engine.rounds[0].samples == [101] }
        engine.rounds[0].partial("已识别的开头")
        try await parityEventually { session.text == "已识别的开头" }
        failure = "所有麦克风恢复失败"
        output.finish()
        try await parityEventually { engine.rounds[0].ended }
        // Drain already-enqueued capture and watchdog tasks before checking.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(session.isRecording, "The hardware input has ended; the UI must leave recording state")
        XCTAssertGreaterThan(clock.pending, 0, "A silent ASR must not keep the failed session alive without a final deadline")
        clock.advance()
        try await parityEventually { !session.isActive }
        XCTAssertEqual(cancelledText, "已识别的开头")
    }

    func testAStuckZeroHeadsetLinkMustNotStaySelectedForever() async throws {
        let native = RegressionNativeInput(), timers = RegressionTailTimers(), clock = RegressionClock()
        let headset = HeadsetMicrophone(microphones: { [self.airPods, self.builtIn] }, makeInput: { native },
            now: { clock.now }, schedule: timers.add, lookback: 0, automaticallyMonitor: false)
        headset.setEnabled(true)
        headset.devicesChanged()
        native.send(1)
        headset.devicesChanged()
        var computerOpens = 0
        let computer = RegressionComputerInput()
        let source = RoutedRecordingSource(preference: .headsetMode,
            microphones: { [self.airPods, self.builtIn] }, makeSource: { mic in
                if mic.isHeadset {
                    guard let tap = headset.tap(for: mic) else { throw ASRError("耳机未就绪") }
                    return tap
                }
                computerOpens += 1
                return computer
            }, now: { clock.now }, automaticallyMonitor: false)
        let stream = try source.start()
        let reader = Task {
            var values: [Int16] = []
            for await frame in stream { values.append(frame[0]) }
            return values
        }
        defer { source.stop(); headset.devicesChanged(); timers.fire(); headset.setEnabled(false); headset.devicesChanged(); reader.cancel() }
        native.send(101)
        headset.devicesChanged()
        for index in 1...20 {
            clock.now = Double(index)
            for _ in 0..<50 { native.send(0) } // One second of PCM, all exact zeros.
            headset.devicesChanged()
            headset.checkHealth()
            for _ in 0..<3 { await Task.yield() }
            source.checkHealth()
        }
        XCTAssertTrue(native.disposed)
        XCTAssertGreaterThan(computerOpens, 0, "A permanently connecting headset must eventually recover or fall back")
        computer.send(102)
        source.stop()
        let values = await reader.value.filter { $0 != 0 }
        XCTAssertEqual(values, [101, 102])
        XCTAssertEqual(values.map { $0 == 101 ? "开头" : "和结尾。" }.joined(), "开头和结尾。")
    }

    func testQuietNonzeroInputAndShortDigitalGapsNeverTriggerRecovery() async throws {
        let native = RegressionNativeInput(), timers = RegressionTailTimers(), clock = RegressionClock()
        let headset = HeadsetMicrophone(microphones: { [self.airPods] }, makeInput: { native },
            now: { clock.now }, schedule: timers.add, automaticallyMonitor: false)
        headset.setEnabled(true)
        headset.devicesChanged()
        let tap = try XCTUnwrap(headset.tap(for: airPods))
        let stream = try tap.start()
        let reader = Task { for await _ in stream {} }
        defer { tap.stop(); headset.devicesChanged(); timers.fire(); headset.setEnabled(false); headset.devicesChanged(); reader.cancel() }
        for index in 1...20 {
            clock.now = Double(index)
            // RMS is far below the speech threshold; occasional 40ms gaps are fine.
            for _ in 0..<48 { native.send(1) }
            native.send(0); native.send(0)
            headset.devicesChanged()
            headset.checkHealth()
        }
        XCTAssertFalse(native.disposed)
        XCTAssertEqual(headset.currentState, .live)
    }

    func testSuspensionPreservesCapturedTextAndNeverOpensTheComputerMic() async throws {
        let native = RegressionNativeInput(), timers = RegressionTailTimers()
        let headset = HeadsetMicrophone(microphones: { [self.airPods, self.builtIn] }, makeInput: { native },
            schedule: timers.add, automaticallyMonitor: false)
        headset.setEnabled(true)
        headset.devicesChanged()
        var computerOpens = 0
        let recorder = Recorder(defaults: try defaults()) { preference in
            RoutedRecordingSource(preference: preference, microphones: { [self.airPods, self.builtIn] }, makeSource: { mic in
                if mic.isHeadset { return try XCTUnwrap(headset.tap(for: mic)) }
                computerOpens += 1; return RegressionComputerInput()
            }, automaticallyMonitor: false)
        }
        let capture = DictationCapture(start: recorder.start, stop: recorder.stop)
        let session = DictationSession(startCapture: capture.take, stopCapture: capture.stop,
            captureFailure: { recorder.failureSnapshot }, makeEngine: { _ in RegressionTextEngine() })
        defer { session.cancel(); headset.setEnabled(false); headset.devicesChanged() }
        var results: [DictationSession.Result] = []
        session.onFinish = { results.append($0) }
        try session.start(channel: .wetype, sendsReturn: true)
        native.send(101)
        try await parityEventually { session.text == "开头" }
        native.send(102, count: 37)
        headset.devicesChanged()
        headset.setSuspended(true)
        headset.devicesChanged()
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results.first?.text, "开头和结尾。")
        XCTAssertNotNil(results.first?.error)
        XCTAssertEqual(results.first?.sendsReturn, false)
        XCTAssertTrue(native.disposed)
        XCTAssertEqual(computerOpens, 0)
    }

    func testDisablingHeadsetDuringRecordingWaitsForTheActualProfileChange() async throws {
        let native = RegressionNativeInput(), timers = RegressionTailTimers(), clock = RegressionClock()
        let hardware = PlaybackHardwareDouble()
        hardware.rates = [hardware.speaker.uid: 24000]
        let silencer = PlaybackSilencer(hardware: hardware, now: { clock.now }, automaticallyRestore: false)
        native.onDispose = { hardware.rates[hardware.speaker.uid] = 48000 }
        let headset = HeadsetMicrophone(microphones: { [self.airPods] }, makeInput: { native },
            schedule: timers.add, automaticallyMonitor: false)
        headset.setEnabled(true)
        headset.devicesChanged()
        let settings = try defaults()
        settings.set(true, forKey: Recorder.mutePlaybackKey)
        let recorder = Recorder(defaults: settings, silencer: silencer) { preference in
            RoutedRecordingSource(preference: preference, microphones: { [self.airPods] },
                makeSource: { try XCTUnwrap(headset.tap(for: $0)) }, automaticallyMonitor: false)
        }
        let stream = try recorder.start()
        native.send(101)
        headset.setEnabled(false)
        headset.devicesChanged()
        recorder.stop()
        try await parityEventually { timers.count == 1 }
        timers.fire()
        headset.devicesChanged()
        for await _ in stream {}
        XCTAssertTrue(native.disposed)
        XCTAssertEqual(hardware.values[hardware.speaker], 1, "Keep mute through the final profile/volume synchronization")
        clock.now = 0.3
        silencer.checkRestoration()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
    }

    func testOldInputEOFAndTimeoutCannotStopAResumedRecording() async throws {
        let capture = ParityCapture(), engine = ParityEngine(), clock = ParityClock()
        capture.finishesOnStop = false
        let session = DictationSession(startCapture: capture.start, stopCapture: capture.stop,
            makeEngine: { _ in engine }, sleep: clock.sleep)
        defer { session.cancel(); capture.close(); engine.close(); clock.advance() }
        var results: [DictationSession.Result] = []
        session.onFinish = { results.append($0) }
        try session.start(channel: .wetype)
        try await parityEventually { engine.rounds.count == 1 }
        session.end()
        try session.start(channel: .wetype)
        try await parityEventually { engine.rounds.count == 2 }
        capture.sources[0].finish()
        try await parityEventually { engine.rounds[0].ended }
        clock.advance()
        engine.rounds[0].resolve(.success("开头"))
        try await parityEventually { session.text == "开头" }
        XCTAssertTrue(session.isRecording)
        session.end()
        capture.sources[1].finish()
        engine.rounds[1].resolve(.success("和结尾。"))
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results.first?.text, "开头和结尾。")
    }

    func testUnreadyHeadsetCannotBypassItsResidentOwnerWithANativeQueue() {
        XCTAssertThrowsError(try RoutedRecordingSource.source(airPods))
    }

    func testScreenSuspensionStopsComputerCaptureAndBlocksNewRecordingsUntilAwake() async throws {
        let hardware = ParityCapture(), engine = ParityEngine()
        let headset = HeadsetMicrophone(microphones: { [] }, automaticallyMonitor: false)
        let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
            enginePool: DictationEnginePool { _ in engine }, defaults: try defaults(), failoverPolicy: nil,
            headset: headset, insertText: { _, _ in })
        defer { app.dictation.cancel(); hardware.close(); engine.close() }
        app.begin(isTap: true)
        try await parityEventually { engine.rounds.count == 1 }
        app.updateScreenSuspension(locked: true)
        XCTAssertFalse(app.dictation.isRecording)
        XCTAssertEqual(hardware.stops, 1)
        app.begin(isTap: true)
        XCTAssertEqual(hardware.sources.count, 1)
        app.updateScreenSuspension(locked: false, asleep: true)
        app.begin(isTap: true)
        XCTAssertEqual(hardware.sources.count, 1)
        app.updateScreenSuspension(asleep: false)
        app.begin(isTap: true)
        XCTAssertEqual(hardware.sources.count, 2)
    }

    func testSuspendStillFinalizesExactTextWithoutSendingReturn() async throws {
        let hardware = ParityCapture(), engine = ParityEngine()
        let session = DictationSession(startCapture: hardware.start, stopCapture: hardware.stop,
            makeEngine: { _ in engine })
        defer { session.cancel(); hardware.close(); engine.close() }
        var results: [DictationSession.Result] = []
        session.onFinish = { results.append($0) }
        try session.start(channel: .wetype, sendsReturn: true)
        try await parityEventually { engine.rounds.count == 1 }
        session.suspend()
        try await parityEventually { engine.rounds[0].ended }
        engine.rounds[0].resolve(.success("开头和结尾。"))
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results, [.init(text: "开头和结尾。", error: nil, sendsReturn: false)])
    }

    func testLateOldTailTimerCannotCloseANewerTapWhenHeadsetModeWasDisabled() async throws {
        let native = RegressionNativeInput(), timers = RegressionTailTimers()
        let headset = HeadsetMicrophone(microphones: { [self.airPods] }, makeInput: { native },
            schedule: timers.add, automaticallyMonitor: false)
        headset.setEnabled(true)
        headset.devicesChanged()
        let first = try XCTUnwrap(headset.tap(for: airPods))
        let old = try first.start()
        native.send(101)
        first.stop()
        headset.devicesChanged()
        let second = try XCTUnwrap(headset.tap(for: airPods))
        let new = try second.start()
        headset.setEnabled(false)
        headset.devicesChanged()
        timers.fire() // Only the superseded tap's timer is pending.
        headset.devicesChanged()
        XCTAssertFalse(native.disposed)
        native.send(102)
        second.stop()
        headset.devicesChanged()
        timers.fire()
        headset.devicesChanged()
        var oldValues: [Int16] = [], newValues: [Int16] = []
        for await frame in old { oldValues.append(frame[0]) }
        for await frame in new { newValues.append(frame[0]) }
        XCTAssertEqual(oldValues, [101])
        XCTAssertEqual(newValues, [102])
        XCTAssertTrue(native.disposed)
    }

    func testRouteChangeCanBeReadFromTheNativeStopCompletion() async throws {
        let native = RegressionNativeInput(), timers = RegressionTailTimers()
        let headset = HeadsetMicrophone(microphones: { [self.airPods] }, makeInput: { native },
            schedule: timers.add, automaticallyMonitor: false)
        headset.setEnabled(true)
        headset.devicesChanged()
        let tap = try XCTUnwrap(headset.tap(for: airPods))
        _ = try tap.start()
        headset.setEnabled(false)
        headset.devicesChanged()
        let stopped = expectation(description: "Route change read without reentering the native queue")
        tap.stop {
            XCTAssertTrue(tap.changesPlaybackRoute)
            stopped.fulfill()
        }
        headset.devicesChanged()
        timers.fire()
        await fulfillment(of: [stopped], timeout: 1)
    }
}
