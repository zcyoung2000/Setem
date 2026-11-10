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
    var subscriptions = 0
    var rates: [String: Float64] = [:]
    init() {
        route = [.init(controls: [speaker])]
        values = [speaker: 0, volume: 0.6]
    }
    func outputs() throws -> [PlaybackOutput] { route }
    func sampleRates() -> [String: Float64] { rates }
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
        subscriptions += 1
        return { [weak self] in self?.changed = nil; self?.watches -= 1 }
    }
}

final class DictationRecorderTests: XCTestCase {
    private final class Input: RecordingSource {
        var onLevel: ((Float) -> Void)?
        var onFailure: ((Error) -> Void)?
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
        var devices: [MicrophonePreference] = [], inputs: [Input] = []
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
        defaults.set(true, forKey: MicrophonePreference.headsetKey)
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
        XCTAssertEqual(devices, [.computer, .headsetMode, .headsetMode])
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
        hardware.route = [.init(controls: [])]
        hardware.changed?()
        recorder.stop()
        hardware.route = [.init(controls: [hardware.volume])]
        let new = try recorder.start()
        let newFailure = recorder.failureSnapshot
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(inputs[1].stops, 0)
        XCTAssertNil(oldFailure())
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
    func testActiveOutputFailureKeepsRecordingAndPreservesExactText() async throws {
        let suite = "OpenVoice-MuteRouteFailure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let hardware = PlaybackHardwareDouble(), input = Input()
        let recorder = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in input }
        let stream = try recorder.start()
        let failure = recorder.failureSnapshot
        hardware.route = [.init(controls: [])]
        hardware.changed?()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(input.stops, 0)
        XCTAssertNil(failure())
        input.output?.yield([103])
        recorder.stop()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        var frames: [[Int16]] = []
        for await frame in stream { frames.append(frame) }
        XCTAssertEqual(frames, [[101], [103], [102]])
        XCTAssertEqual(frames.map { $0[0] == 101 ? "开头" : $0[0] == 103 ? "继续" : "和结尾。" }.joined(), "开头继续和结尾。")
    }

    func testUnsupportedOutputDoesNotPreventMicrophoneCapture() throws {
        let suite = "OpenVoice-MuteUnsupported-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Recorder.mutePlaybackKey)
        let hardware = PlaybackHardwareDouble(), input = Input()
        hardware.route = [.init(controls: [])]
        var starts = 0
        input.starting = { starts += 1 }
        let recorder = Recorder(defaults: defaults, silencer: PlaybackSilencer(hardware: hardware)) { _ in input }
        _ = try recorder.start()
        XCTAssertEqual(starts, 1)
        recorder.stop()
        XCTAssertEqual(hardware.watches, 0)
    }
}

final class DictationPlaybackMuteTests: XCTestCase {
    func testHeadsetRestorationWaitsForPlaybackProfileAndItsVolumeSynchronization() {
        let hardware = PlaybackHardwareDouble()
        var clock: TimeInterval = 0
        hardware.rates = [hardware.speaker.uid: 24000]
        let silencer = PlaybackSilencer(hardware: hardware, now: { clock }, automaticallyRestore: false)
        let lease = silencer.acquire()
        hardware.rates[hardware.speaker.uid] = 24000
        lease.finish(afterRouteChange: true)
        clock = 2
        silencer.checkRestoration()
        XCTAssertEqual(hardware.values[hardware.speaker], 1, "No playback in the temporary recording profile")
        hardware.rates[hardware.speaker.uid] = 48000
        hardware.values[hardware.speaker] = 0 // Bluetooth profile replacement clears mute.
        hardware.changed?()
        XCTAssertEqual(hardware.values[hardware.speaker], 1, "Protect playback while the driver synchronizes volume")
        clock = 2.2
        hardware.changed?() // A later stream/format notification restarts the quiet period.
        clock = 2.3
        silencer.checkRestoration()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        clock = 2.5
        silencer.checkRestoration()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        XCTAssertEqual(hardware.watches, 0)
        XCTAssertEqual(hardware.writes.map(\.1), [1, 1, 0], "One restoration after profile and volume settle")
    }

    func testNewCaptureCancelsOldRestorationAndKeepsOriginalPlaybackProfile() {
        let hardware = PlaybackHardwareDouble()
        var clock: TimeInterval = 0
        hardware.rates = [hardware.speaker.uid: 24000]
        let silencer = PlaybackSilencer(hardware: hardware, now: { clock }, automaticallyRestore: false)
        let first = silencer.acquire()
        hardware.rates[hardware.speaker.uid] = 24000
        first.finish(afterRouteChange: true)
        let second = silencer.acquire()
        clock = 4
        silencer.checkRestoration()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        second.finish(afterRouteChange: true)
        clock = 4.5
        silencer.checkRestoration()
        XCTAssertEqual(hardware.values[hardware.speaker], 1, "Inherit playback profile, not the preceding capture's HFP rate")
        hardware.rates[hardware.speaker.uid] = 48000
        hardware.changed?()
        clock = 4.8
        silencer.checkRestoration()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testHeadsetRestorationIsBoundedAndPreservesUserVolumeChanges() {
        let hardware = PlaybackHardwareDouble()
        var clock: TimeInterval = 0
        hardware.route = [.init(controls: [hardware.volume])]
        hardware.rates = [hardware.volume.uid: 24000]
        let silencer = PlaybackSilencer(hardware: hardware, now: { clock }, automaticallyRestore: false)
        let lease = silencer.acquire()
        hardware.rates[hardware.volume.uid] = 24000 // Another app continues using the mic.
        lease.finish(afterRouteChange: true)
        hardware.values[hardware.volume] = 0.35
        clock = 3
        silencer.checkRestoration()
        XCTAssertEqual(hardware.values[hardware.volume], 0.35)
        XCTAssertEqual(hardware.watches, 0)
        XCTAssertEqual(hardware.writes.map(\.1), [0])
    }

    func testBuiltInCaptureDoesNotWaitForConnectedHeadphonesToChangeProfile() {
        let hardware = PlaybackHardwareDouble()
        hardware.rates = [hardware.speaker.uid: 48000]
        let silencer = PlaybackSilencer(hardware: hardware, automaticallyRestore: false)
        let lease = silencer.acquire()
        lease.finish()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testListenerInstallationNotificationsDrainAndRouteChangesOnlyReplaceChangedDevices() throws {
        var route: Set<String> = ["system", "speaker"]
        var installed: [String: () -> Void] = [:]
        var queued: [() -> Void] = []
        var additions: [String] = [], removals: [String] = []
        var changes = 0
        let observation = PlaybackRouteObservation(properties: { route }, install: { property, notify in
            additions.append(property)
            installed[property] = notify
            queued.append(notify) // Core Audio may notify immediately after installation.
            return { removals.append(property); installed[property] = nil }
        }, changed: { changes += 1 })
        defer { observation.stop() }
        func drain() {
            var delivered = 0
            while !queued.isEmpty, delivered < 20 {
                let notify = queued.removeFirst()
                notify()
                delivered += 1
            }
            XCTAssertTrue(queued.isEmpty, "Listener notifications must settle without a feedback loop")
        }
        drain()
        XCTAssertEqual(additions.count, 2)
        XCTAssertEqual(changes, 2)
        let systemNotification = try XCTUnwrap(installed["system"])
        for _ in 0..<100 { systemNotification() }
        XCTAssertEqual(additions.count, 2)
        XCTAssertTrue(removals.isEmpty)
        let staleSpeakerNotification = try XCTUnwrap(installed["speaker"])
        route = ["system", "headphones"]
        systemNotification()
        drain()
        XCTAssertEqual(additions.count, 3)
        XCTAssertEqual(removals, ["speaker"])
        XCTAssertEqual(Set(installed.keys), route)
        observation.stop()
        let count = changes
        staleSpeakerNotification()
        systemNotification()
        XCTAssertEqual(changes, count)
        XCTAssertTrue(installed.isEmpty)
        XCTAssertEqual(additions.count, 3)
        XCTAssertEqual(removals.count, 3)
    }

    func testRepeatedRouteNotificationsKeepOneSubscriptionAndRestorePlayback() throws {
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        let lease = silencer.acquire()
        let notification = try XCTUnwrap(hardware.changed)
        // Listener installation can itself queue Core Audio route notifications.
        // Processing those notifications must not install another listener.
        for _ in 0..<100 { notification() }
        XCTAssertEqual(hardware.subscriptions, 1)
        XCTAssertEqual(hardware.writes.count, 1)
        hardware.route = [.init(controls: [hardware.volume])]
        notification()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        lease.finish()
        notification() // A queued notification after teardown cannot re-subscribe.
        XCTAssertEqual(hardware.watches, 0)
        XCTAssertEqual(hardware.subscriptions, 1)
    }

    func testHeadphonesAreMutedAndRestoreTheOriginalVolume() throws {
        let hardware = PlaybackHardwareDouble()
        hardware.route = [.init(controls: [hardware.volume])]
        let silencer = PlaybackSilencer(hardware: hardware)
        let lease = silencer.acquire()
        XCTAssertEqual(hardware.values[hardware.volume], 0)
        lease.finish()
        XCTAssertEqual(hardware.values[hardware.volume], 0.6)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testSwitchingBetweenSpeakersAndHeadphonesRestoresEachDevice() throws {
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        let lease = silencer.acquire()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        hardware.route = [.init(controls: [hardware.volume])]
        hardware.changed?()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        hardware.route = [.init(controls: [hardware.volume])]
        hardware.changed?()
        XCTAssertEqual(hardware.values[hardware.volume], 0)
        lease.finish()
        XCTAssertEqual(hardware.values[hardware.volume], 0.6)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testMultipleRecordersCannotUnmuteEachOtherAndShutdownRestoresAll() throws {
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        let first = silencer.acquire(), second = silencer.acquire()
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
        let first = silencer.acquire()
        first.finish()
        XCTAssertTrue(hardware.writes.isEmpty)
        hardware.route = [.init(controls: [hardware.volume])]
        let next = silencer.acquire()
        XCTAssertEqual(hardware.values[hardware.volume], 0)
        hardware.values[hardware.volume] = 0.35 // User adjusted it while dictating.
        next.finish()
        XCTAssertEqual(hardware.values[hardware.volume], 0.35)
    }

    func testDisconnectedHeadsetRestoresByUIDAfterCaptureEndsAndDeviceIDChanges() {
        let hardware = PlaybackHardwareDouble()
        hardware.route = [.init(controls: [hardware.volume])]
        let silencer = PlaybackSilencer(hardware: hardware)
        let lease = silencer.acquire()
        XCTAssertEqual(hardware.values[hardware.volume], 0)
        hardware.values[hardware.volume] = nil
        hardware.route = [.init(controls: [hardware.speaker])]
        hardware.changed?()
        lease.finish()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        let reconnected = PlaybackControl(device: 99, uid: hardware.volume.uid, element: 1, kind: .volume)
        hardware.values[reconnected] = 0
        hardware.route = [.init(controls: [reconnected])]
        hardware.changed?()
        XCTAssertEqual(hardware.values[reconnected], 0.6, "Reconnect must restore the endpoint we muted, using its UID")
        XCTAssertEqual(hardware.watches, 0)
    }

    func testMuteRetriesAfterTransientHeadsetProfileFailure() {
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        var warnings = 0
        hardware.route = [.init(controls: [])]
        let lease = silencer.acquire { _ in warnings += 1 }
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(hardware.watches, 1)
        hardware.route = [.init(controls: [hardware.volume])]
        hardware.changed?()
        XCTAssertEqual(hardware.values[hardware.volume], 0)
        hardware.route = [.init(controls: [])]
        hardware.changed?()
        XCTAssertEqual(hardware.values[hardware.volume], 0)
        XCTAssertEqual(warnings, 2)
        hardware.route = [.init(controls: [hardware.volume])]
        hardware.changed?()
        lease.finish()
        XCTAssertEqual(hardware.values[hardware.volume], 0.6)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testUnsupportedOutputKeepsObservationAndRollsBackChangedChannels() throws {
        let hardware = PlaybackHardwareDouble()
        let silencer = PlaybackSilencer(hardware: hardware)
        hardware.route = [.init(controls: [])]
        var failures = 0
        let first = silencer.acquire { _ in failures += 1 }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(hardware.watches, 1)
        first.finish()
        hardware.route = [.init(controls: [hardware.speaker, hardware.volume])]
        hardware.failControl = hardware.volume
        let second = silencer.acquire { _ in failures += 1 }
        XCTAssertEqual(failures, 2)
        second.finish()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
        XCTAssertEqual(hardware.values[hardware.volume], 0.6)
        XCTAssertEqual(hardware.watches, 0)
    }

    func testSystemAlertSpeakersAreMutedEvenWhenMainOutputIsHeadphones() throws {
        let hardware = PlaybackHardwareDouble()
        hardware.route = [.init(controls: [hardware.volume]),
                          .init(controls: [hardware.speaker])]
        let silencer = PlaybackSilencer(hardware: hardware)
        let lease = silencer.acquire()
        XCTAssertEqual(hardware.values[hardware.speaker], 1)
        lease.finish()
        XCTAssertEqual(hardware.values[hardware.speaker], 0)
    }
}
