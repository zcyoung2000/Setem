import CoreAudio
import XCTest
@testable import OpenVoice

final class PlaybackHardwareDouble: PlaybackHardware {
    let speaker = PlaybackControl(device: 1, uid: "speaker", element: 0, kind: .mute)
    let volume = PlaybackControl(device: 2, uid: "usb-speaker", element: 1, kind: .volume)
    var route: [PlaybackOutput] = []
    var values: [PlaybackControl: Float32] = [:]
    var writes: [(PlaybackControl, Float32)] = []
    var changed: (() -> Void)?
    var failControl: PlaybackControl?
    var watches = 0
    init() {
        route = [.init(isHeadphones: false, controls: [speaker])]
        values = [speaker: 0, volume: 0.6]
    }
    func outputs() throws -> [PlaybackOutput] { route }
    func value(_ control: PlaybackControl) throws -> Float32 {
        guard let value = values[control] else { throw ASRError("设备已断开") }
        return value
    }
    func set(_ value: Float32, for control: PlaybackControl) throws {
        if control == failControl { throw ASRError("设备不支持静音") }
        values[control] = value
        writes.append((control, value))
    }
    func observe(_ changed: @escaping () -> Void) -> () -> Void {
        self.changed = changed
        watches += 1
        return { [weak self] in self?.changed = nil; self?.watches -= 1 }
    }
}

final class DictationRecorderTests: XCTestCase {
    private final class Input: RecordingSource {
        var onLevel: ((Float) -> Void)?
        var output: AsyncStream<[Int16]>.Continuation?
        var stops = 0
        var fails = false
        var starting: (() -> Void)?
        func start() throws -> AsyncStream<[Int16]> {
            starting?()
            let (stream, output) = AsyncStream<[Int16]>.makeStream()
            self.output = output
            if fails { throw ASRError("麦克风不可用") }
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

    func testSettingSnapshotsEachCaptureAndRestoresAtStopWithExactTail() async throws {
        let suite = "OpenVoice-MuteCapture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        var devices: [String] = [], inputs: [Input] = []
        let recorder = Recorder(defaults: defaults, silencer: silencer) { uid in
            devices.append(uid)
            let input = Input()
            inputs.append(input)
            let expectedMute: Float32 = inputs.count == 2 ? 1 : 0
            input.starting = {
                XCTAssertEqual(hardware.values[hardware.speaker], expectedMute,
                               "Mute must be applied before microphone capture begins")
            }
            return input
        }
        var levels: [Float] = []
        recorder.onLevel = { levels.append($0) }
        let first = try recorder.start()
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        defaults.set("chosen-device", forKey: "micUID")
        XCTAssertThrowsError(try recorder.start())
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        recorder.stop()
        recorder.stop()
        var frames: [[Int16]] = []
        for await frame in first { frames.append(frame) }
        XCTAssertEqual(frames, [[101], [102]])
        XCTAssertEqual(inputs[0].stops, 1)

        let second = try recorder.start()
        defaults.set(false, forKey: Recorder.mutePlaybackKey)
        XCTAssertEqual(hardware.values[hardware.speaker], 1, "Changing settings cannot unmute an active capture")
        recorder.stop()
        XCTAssertEqual(hardware.values[hardware.speaker], 0, "Restore before waiting for recognition/final consumption")
        XCTAssertEqual(hardware.watches, 0)
        let third = try recorder.start()
        recorder.stop()
        for await _ in second {}
        for await _ in third {}
        XCTAssertEqual(devices, ["", "chosen-device", "chosen-device"])
        XCTAssertEqual(levels, [0.5, 0.5, 0.5])
    }

    func testMicrophoneFailureRestoresPlaybackAndAllowsRetry() async throws {
        let suite = "OpenVoice-MuteFailure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let hardware = PlaybackHardwareDouble()
        let failed = Input(), next = Input()
        failed.fails = true
        var count = 0
        let recorder = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in
            count += 1
            return count == 1 ? failed : next
        }
        XCTAssertThrowsError(try recorder.start())
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        XCTAssertEqual(failed.stops, 1)
        XCTAssertEqual(hardware.watches, 0)
        let stream = try recorder.start()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        recorder.stop()
        var frames: [[Int16]] = []
        for await frame in stream { frames.append(frame) }
        XCTAssertEqual(frames, [[101], [102]])
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
    }

    @MainActor
    func testLateOutputFailureCannotStopNextCaptureOrReplaceItsFailure() async throws {
        let suite = "OpenVoice-MuteOwnership-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let hardware = PlaybackHardwareDouble()
        var inputs: [Input] = []
        let recorder = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in
            let input = Input(); inputs.append(input); return input
        }
        let old = try recorder.start()
        let oldFailure = recorder.failureSnapshot
        hardware.route = [.init(isHeadphones: false, controls: [])]
        hardware.changed?()
        recorder.stop()
        hardware.route = [.init(isHeadphones: true, controls: [])]
        let new = try recorder.start()
        let newFailure = recorder.failureSnapshot
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(inputs[1].stops, 0)
        XCTAssertNotNil(oldFailure())
        XCTAssertNil(newFailure())
        recorder.stop()
        for await _ in old {}
        for await _ in new {}
    }

    func testRecorderDestructionRestoresPlaybackWithoutARecognitionCallback() throws {
        let suite = "OpenVoice-MuteDeinit-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let hardware = PlaybackHardwareDouble()
        let input = Input()
        var recorder: Recorder? = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in input }
        _ = try recorder?.start()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        recorder = nil
        XCTAssertEqual(input.stops, 1)
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        XCTAssertEqual(hardware.watches, 0)
    }

    @MainActor
    func testActiveOutputFailureFinishesItsAudioTailAndReportsTheCause() async throws {
        let suite = "OpenVoice-MuteRouteFailure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let hardware = PlaybackHardwareDouble(), input = Input()
        let recorder = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in input }
        let stream = try recorder.start()
        let failure = recorder.failureSnapshot
        hardware.route = [.init(isHeadphones: false, controls: [])]
        hardware.changed?()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(input.stops, 1)
        XCTAssertNotNil(failure())
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        var frames: [[Int16]] = []
        for await frame in stream { frames.append(frame) }
        XCTAssertEqual(frames, [[101], [102]])
    }

    func testUnsupportedOutputNeverStartsAnUnmutedMicrophone() throws {
        let suite = "OpenVoice-MuteUnsupported-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let hardware = PlaybackHardwareDouble(), input = Input()
        hardware.route = [.init(isHeadphones: false, controls: [])]
        var starts = 0
        input.starting = { starts += 1 }
        let recorder = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in input }
        XCTAssertThrowsError(try recorder.start())
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(hardware.watches, 0)
    }
}

final class DictationPlaybackMuteTests: XCTestCase {
    func testHeadphonesSkipMuteButBluetoothOrUSBUnknownTypesDoNot() throws {
        XCTAssertTrue(PlaybackOutput.headphones(terminalTypes: [kAudioStreamTerminalTypeHeadphones]))
        XCTAssertFalse(PlaybackOutput.headphones(terminalTypes: [kAudioStreamTerminalTypeSpeaker]))
        XCTAssertFalse(PlaybackOutput.headphones(terminalTypes: [0]))
        XCTAssertFalse(PlaybackOutput.headphones(terminalTypes: []))
        XCTAssertFalse(PlaybackOutput.headphones(terminalTypes: [kAudioStreamTerminalTypeHeadphones, kAudioStreamTerminalTypeSpeaker]))
        let hardware = PlaybackHardwareDouble()
        hardware.route = [.init(isHeadphones: true, controls: [])]
        let silencer = PlaybackSilencer(hardware: hardware)
        let lease = try silencer.acquire()
        XCTAssertTrue(hardware.writes.isEmpty)
        lease.finish()
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testSwitchingBetweenSpeakersAndHeadphonesRestoresEachDevice() throws {
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        let lease = try silencer.acquire()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        hardware.route = [.init(isHeadphones: true, controls: [])]
        hardware.changed?()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        hardware.route = [.init(isHeadphones: false, controls: [hardware.volume])]
        hardware.changed?()
        XCTAssertEqual(hardware.values[hardware.volume], 0)
        lease.finish()
        XCTAssertEqual(hardware.values[hardware.volume], 0.6)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testMultipleRecordersCannotUnmuteEachOtherAndShutdownRestoresAll() throws {
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        let first = try silencer.acquire(), second = try silencer.acquire()
        XCTAssertEqual(hardware.writes.count, 1)
        first.finish()
        first.finish()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        XCTAssertEqual(hardware.watches, 1)
        silencer.restoreAll()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        second.finish()
        XCTAssertEqual(hardware.watches, 0)
    }

    func testPreexistingMuteAndUserVolumeAdjustmentRemainUntouched() throws {
        let hardware = PlaybackHardwareDouble()
        hardware.values[hardware.speaker] = 1
        let silencer = PlaybackSilencer(hardware: hardware)
        let first = try silencer.acquire()
        first.finish()
        XCTAssertTrue(hardware.writes.isEmpty)
        hardware.route = [.init(isHeadphones: false, controls: [hardware.volume])]
        let next = try silencer.acquire()
        XCTAssertEqual(hardware.values[hardware.volume], 0)
        hardware.values[hardware.volume] = 0.35 // User adjusted it while dictating.
        next.finish()
        XCTAssertEqual(hardware.values[hardware.volume], 0.35)
    }

    func testUnsupportedOutputFailsBeforeRecordingAndRollsBackChangedChannels() throws {
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        hardware.route = [.init(isHeadphones: false, controls: [])]
        XCTAssertThrowsError(try silencer.acquire())
        XCTAssertEqual(hardware.watches, 0)
        hardware.route = [.init(isHeadphones: false, controls: [hardware.speaker, hardware.volume])]
        hardware.failControl = hardware.volume
        XCTAssertThrowsError(try silencer.acquire())
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        XCTAssertEqual(hardware.values[hardware.volume], 0.6)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testSystemAlertSpeakersAreMutedEvenWhenMainOutputIsHeadphones() throws {
        let hardware = PlaybackHardwareDouble()
        hardware.route = [.init(isHeadphones: true, controls: []),
                          .init(isHeadphones: false, controls: [hardware.speaker])]
        let silencer = PlaybackSilencer(hardware: hardware)
        let lease = try silencer.acquire()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        lease.finish()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
    }
}
