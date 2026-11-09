import CoreAudio
import XCTest
@testable import OpenVoice

private final class RoutingInputDouble: RecordingSource {
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?
    var output: AsyncStream<[Int16]>.Continuation?
    var startError: Error?
    var stops = 0
    var finishOnStop = true
    var changesPlaybackRoute = false
    func start() throws -> AsyncStream<[Int16]> {
        if let startError { throw startError }
        let (stream, output) = AsyncStream<[Int16]>.makeStream()
        self.output = output
        return stream
    }
    func send(_ value: Int16) { output?.yield([Int16](repeating: value, count: 320)) }
    func stop() { stops += 1; if finishOnStop { output?.finish() } }
}

@MainActor
final class DictationRoutingTests: XCTestCase {
    private let builtIn = Microphone(id: "builtin", name: "MacBook 麦克风", deviceID: 1, transport: kAudioDeviceTransportTypeBuiltIn)
    private let airPods = Microphone(id: "airpods", name: "AirPods", deviceID: 2, transport: kAudioDeviceTransportTypeBluetooth)

    func testAirPodsFailurePreservesOneRecognitionStreamAndExactFinal() async throws {
        var available = [builtIn, airPods]
        var opened: [String] = []
        var inputs: [RoutingInputDouble] = []
        let source = RoutedRecordingSource(preference: .headsetMode, microphones: { available }, makeSource: { microphone in
            let uid = microphone.id
            opened.append(uid)
            let input = RoutingInputDouble(); inputs.append(input); return input
        }, automaticallyMonitor: false)
        let suite = "OpenVoice-RoutingSession-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder(defaults: defaults) { _ in source }
        let capture = DictationCapture(start: recorder.start, stop: recorder.stop)
        let session = DictationSession(startCapture: capture.take, stopCapture: capture.stop,
                                      captureFailure: { recorder.failureSnapshot }, makeEngine: { _ in RoutingTextEngine() })
        var results: [DictationSession.Result] = []
        session.onFinish = { results.append($0) }
        try session.start(channel: .wetype, sendsReturn: false)
        inputs[0].send(101)
        try await parityEventually { session.text == "开头" }
        available = [builtIn]
        let staleError = inputs[0].onFailure
        inputs[0].onFailure?(ASRError("设备已离开 Mac"))
        try await parityEventually { opened == ["airpods", "builtin"] }
        XCTAssertTrue(session.isRecording)
        XCTAssertTrue(results.isEmpty)
        available = [builtIn, airPods]
        source.checkHealth()
        inputs[0].send(999)
        staleError?(ASRError("迟到的旧错误"))
        inputs[1].send(102)
        try await parityEventually { session.text == "开头和结尾。" }
        XCTAssertEqual(opened, ["airpods", "builtin"], "Reconnection waits for the next recording")
        session.end()
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results, [.init(text: "开头和结尾。", error: nil, sendsReturn: false)])
        source.checkHealth()
        XCTAssertEqual(opened.count, 2)
    }

    func testNoCallbackRecoveryIsBoundedAndKeepsAlreadyCapturedFrames() async throws {
        var clock: TimeInterval = 0
        var inputs: [RoutingInputDouble] = []
        let source = RoutedRecordingSource(preference: .computer, microphones: { [self.builtIn, self.airPods] }, makeSource: { microphone in
            let uid = microphone.id
            XCTAssertEqual(uid, "builtin")
            let input = RoutingInputDouble(); inputs.append(input); return input
        }, now: { clock }, automaticallyMonitor: false)
        var failure: String?
        source.onFailure = { failure = $0.localizedDescription }
        let stream = try source.start()
        let collected = Task { var values: [Int16] = []; for await frame in stream { values.append(frame[0]) }; return values }
        inputs[0].send(101)
        try await Task.sleep(for: .milliseconds(20))
        clock = 6
        source.checkHealth()
        try await parityEventually { inputs.count == 2 }
        inputs[1].send(102)
        try await Task.sleep(for: .milliseconds(20))
        clock = 12
        source.checkHealth()
        try await parityEventually { failure != nil }
        let values = await collected.value
        XCTAssertEqual(values, [101, 102])
        XCTAssertEqual(inputs.count, 2)
        source.checkHealth()
        XCTAssertEqual(inputs.count, 2)
    }

    func testSilentFramesAreDeliveredWithoutFalseStallAndWholeZeroInputIsDiagnosed() async throws {
        var clock: TimeInterval = 0
        let input = RoutingInputDouble()
        var opens = 0, failure: String?
        let source = RoutedRecordingSource(preference: .computer, microphones: { [self.builtIn] }, makeSource: { _ in
            opens += 1; return input
        }, now: { clock }, automaticallyMonitor: false)
        source.onFailure = { failure = $0.localizedDescription }
        let stream = try source.start()
        let collected = Task { var count = 0; for await _ in stream { count += 1 }; return count }
        for index in 0..<10 {
            clock = Double(index * 4)
            input.send(0)
            try await Task.sleep(for: .milliseconds(5))
            source.checkHealth()
        }
        XCTAssertEqual(opens, 1)
        XCTAssertNil(failure)
        source.stop()
        let count = await collected.value
        XCTAssertEqual(count, 10)
        XCTAssertEqual(failure, "未收到有效音频，请检查麦克风后重试")
    }

    func testStartupFailureFallsBackAndNeverUsesSystemDefault() async throws {
        var opened: [String] = []
        let source = RoutedRecordingSource(preference: .headsetMode, microphones: { [self.builtIn, self.airPods] }, makeSource: { microphone in
            let uid = microphone.id
            opened.append(uid)
            let input = RoutingInputDouble()
            if uid == "airpods" { input.startError = ASRError("打不开耳机") }
            return input
        }, automaticallyMonitor: false)
        let stream = try source.start()
        source.stop()
        for await _ in stream {}
        XCTAssertEqual(opened, ["airpods", "airpods", "builtin"])
        let fixed = RoutedRecordingSource(preference: .computer, microphones: { [self.airPods] }, makeSource: { _ in
            XCTFail("Unavailable built-in input must never follow the system default"); return RoutingInputDouble()
        }, automaticallyMonitor: false)
        XCTAssertThrowsError(try fixed.start())
    }

    func testRecorderReleaseStillForwardsTheDelayedTail() async throws {
        let input = RoutingInputDouble()
        input.finishOnStop = false
        let microphone = airPods
        let suite = "OpenVoice-RoutingTail-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder(defaults: defaults) { _ in
            RoutedRecordingSource(preference: .headsetMode, microphones: { [microphone] },
                                  makeSource: { _ in input }, automaticallyMonitor: false)
        }
        let stream = try recorder.start()
        let frames = Task { var values: [Int16] = []; for await frame in stream { values.append(frame[0]) }; return values }
        input.send(101)
        recorder.stop()
        input.send(102)
        input.output?.finish()
        let values = await frames.value
        XCTAssertEqual(values, [101, 102], "Key-up releases Recorder ownership before Bluetooth tail delivery")
    }

    func testPlaybackStaysMutedUntilTheBluetoothTailHasBeenDelivered() async throws {
        let input = RoutingInputDouble()
        input.finishOnStop = false
        input.changesPlaybackRoute = true
        let hardware = PlaybackHardwareDouble()
        let microphone = airPods
        let suite = "OpenVoice-RoutingMuteTail-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let recorder = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in
            RoutedRecordingSource(preference: .headsetMode, microphones: { [microphone] },
                                  makeSource: { _ in input }, automaticallyMonitor: false)
        }
        let stream = try recorder.start()
        let frames = Task { var values: [Int16] = []; for await frame in stream { values.append(frame[0]) }; return values }
        input.send(101)
        recorder.stop()
        XCTAssertEqual(hardware.values[hardware.speaker], 1, "Key-up must not unmute while the headset tail is pending")
        input.send(102)
        input.output?.finish()
        let values = await frames.value
        XCTAssertEqual(values, [101, 102])
        try await parityEventually { hardware.values[hardware.speaker] == 0 }
    }

    func testOldTailCompletionCannotUnmuteOrStopTheNextRecording() async throws {
        let hardware = PlaybackHardwareDouble()
        let microphone = airPods
        var inputs: [RoutingInputDouble] = []
        let suite = "OpenVoice-RoutingMuteOverlap-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let recorder = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in
            let input = RoutingInputDouble()
            input.finishOnStop = false
            inputs.append(input)
            return RoutedRecordingSource(preference: .headsetMode, microphones: { [microphone] },
                makeSource: { _ in input }, automaticallyMonitor: false)
        }
        let old = try recorder.start()
        inputs[0].send(101)
        recorder.stop()
        let new = try recorder.start()
        inputs[1].send(201)
        inputs[0].send(102)
        inputs[0].output?.finish()
        var oldValues: [Int16] = []
        for await frame in old { oldValues.append(frame[0]) }
        XCTAssertEqual(oldValues, [101, 102])
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        XCTAssertEqual(inputs[1].stops, 0)
        recorder.stop()
        inputs[1].send(202)
        inputs[1].output?.finish()
        var newValues: [Int16] = []
        for await frame in new { newValues.append(frame[0]) }
        XCTAssertEqual(newValues, [201, 202])
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
    }

    func testStopDuringRecoveryDrainsWithoutOpeningAnotherInput() async throws {
        let input = RoutingInputDouble()
        input.finishOnStop = false
        var opens = 0
        let source = RoutedRecordingSource(preference: .computer, microphones: { [self.builtIn] }, makeSource: { _ in
            opens += 1; return input
        }, automaticallyMonitor: false)
        let stream = try source.start()
        let frames = Task { var values: [Int16] = []; for await frame in stream { values.append(frame[0]) }; return values }
        input.send(101)
        input.onFailure?(ASRError("输入中断"))
        try await parityEventually { input.stops > 0 }
        source.stop()
        input.send(102)
        input.output?.finish()
        let values = await frames.value
        XCTAssertEqual(values, [101, 102])
        XCTAssertEqual(opens, 1)
        source.checkHealth()
        XCTAssertEqual(opens, 1)
    }

    func testFirstCallbackTimeoutReopensTheSameDeviceOnlyOnce() async throws {
        var clock: TimeInterval = 0
        var inputs: [RoutingInputDouble] = []
        let source = RoutedRecordingSource(preference: .computer, microphones: { [self.builtIn] }, makeSource: { _ in
            let input = RoutingInputDouble(); inputs.append(input); return input
        }, now: { clock }, automaticallyMonitor: false)
        let stream = try source.start()
        let frames = Task { var values: [Int16] = []; for await frame in stream { values.append(frame[0]) }; return values }
        clock = 9
        source.checkHealth()
        try await parityEventually { inputs.count == 2 }
        inputs[1].send(101)
        source.stop()
        let values = await frames.value
        XCTAssertEqual(values, [101])
        XCTAssertEqual(inputs.count, 2)
    }

    func testExhaustedInputRecoveryStillCommitsCapturedFinalWithCloudFailoverEnabled() async throws {
        var clock: TimeInterval = 0
        var inputs: [RoutingInputDouble] = []
        let source = RoutedRecordingSource(preference: .computer, microphones: { [self.builtIn] }, makeSource: { _ in
            let input = RoutingInputDouble(); inputs.append(input); return input
        }, now: { clock }, automaticallyMonitor: false)
        let suite = "OpenVoice-RoutingExhausted-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder(defaults: defaults) { _ in source }
        let capture = DictationCapture(start: recorder.start, stop: recorder.stop)
        let engine = RoutingFinalEngine()
        let pool = DictationEnginePool { _ in engine }
        let session = DictationSession(startCapture: capture.take, stopCapture: capture.stop,
            captureFailure: { recorder.failureSnapshot }, enginePool: pool, replayPool: pool, failoverPolicy: .automatic)
        var results: [DictationSession.Result] = []
        session.onFinish = { results.append($0) }
        try session.start(channel: .wetype, sendsReturn: true)
        inputs[0].send(101)
        try await parityEventually { session.text == "临时预览" }
        clock = 6
        source.checkHealth()
        try await parityEventually { inputs.count == 2 }
        inputs[1].send(102)
        try await parityEventually { engine.samples == [101, 102] }
        clock = 12
        source.checkHealth()
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results.first?.text, "开头和结尾。")
        XCTAssertNotNil(results.first?.error)
        XCTAssertEqual(results.first?.sendsReturn, false)
    }

    func testPreferenceMigrationRetiresLegacyModeAndDeviceSelection() throws {
        let usb = Microphone(id: "usb", name: "USB 麦克风", deviceID: 3, transport: kAudioDeviceTransportTypeUSB)
        let cases: [(mode: String?, uid: String?, headset: Bool, computer: String)] = [
            (nil, nil, false, ""),
            ("airPodsPreferred", nil, true, ""),
            ("builtIn", "airpods", false, ""),
            (nil, "airpods", true, ""),
            ("builtIn", nil, false, ""),
            (nil, "usb", false, "usb"),
            (nil, "unplugged", false, ""),
        ]
        for item in cases {
            let name = "OpenVoice-Routing-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(item.mode, forKey: "microphoneMode")
            defaults.set(item.uid, forKey: "micUID")
            MicrophonePreference.migrate(in: defaults, microphones: [builtIn, airPods, usb])
            XCTAssertEqual(MicrophonePreference.current(in: defaults), .init(headset: item.headset, computerUID: item.computer), "\(item)")
            XCTAssertNil(defaults.object(forKey: "microphoneMode"))
            XCTAssertNil(defaults.object(forKey: "micUID"))
            // A later explicit choice is never overwritten by a second migration.
            defaults.set(!item.headset, forKey: MicrophonePreference.headsetKey)
            defaults.set("airPodsPreferred", forKey: "microphoneMode")
            MicrophonePreference.migrate(in: defaults, microphones: [builtIn, airPods, usb])
            XCTAssertEqual(MicrophonePreference.current(in: defaults).headset, !item.headset)
        }
    }

    func testComputerMicrophoneUsesExternalInputAndNeverAHeadsetOrVirtualDevice() throws {
        let usb = Microphone(id: "usb", name: "USB 麦克风", deviceID: 3, transport: kAudioDeviceTransportTypeUSB)
        let loopback = Microphone(id: "loop", name: "Loopback", deviceID: 4, transport: kAudioDeviceTransportTypeVirtual)
        XCTAssertEqual(Microphone.computer("usb", in: [builtIn, airPods, usb])?.id, "usb")
        XCTAssertEqual(Microphone.computer("usb", in: [builtIn, airPods])?.id, "builtin", "Unplugged falls back to built-in")
        XCTAssertEqual(Microphone.computer("airpods", in: [builtIn, airPods])?.id, "builtin")
        XCTAssertEqual(Microphone.computer("loop", in: [builtIn, loopback])?.id, "builtin")
        XCTAssertNil(Microphone.computer("", in: [airPods, usb]), "Never silently follows another input")
        XCTAssertFalse(loopback.isComputerInput)
        XCTAssertTrue(usb.isComputerInput)
        var opened: [String] = []
        let source = RoutedRecordingSource(preference: .init(headset: false, computerUID: "usb"),
                                           microphones: { [self.airPods, self.builtIn, usb] }, makeSource: {
            opened.append($0.id); return RoutingInputDouble()
        }, automaticallyMonitor: false)
        _ = try source.start()
        source.stop()
        XCTAssertEqual(opened, ["usb"])
    }
}

extension MicrophonePreference {
    static let computer = Self(headset: false, computerUID: "")
    static let headsetMode = Self(headset: true, computerUID: "")
}

@MainActor
private final class RoutingTextEngine: ASREngine {
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        var text = ""
        for await frame in audio {
            text += frame[0] == 101 ? "开头" : frame[0] == 102 ? "和结尾。" : "错误"
            partial(text)
        }
        return text
    }
}

@MainActor
private final class RoutingFinalEngine: ASREngine {
    var samples: [Int16] = []
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        var text = ""
        for await frame in audio {
            samples.append(frame[0])
            text += frame[0] == 101 ? "开头" : "和结尾。"
            partial("临时预览")
        }
        return text
    }
}
