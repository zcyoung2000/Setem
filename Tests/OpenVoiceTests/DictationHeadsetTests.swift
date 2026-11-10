import AppKit
import CoreAudio
import XCTest
@testable import OpenVoice

/// Native headset input: zeros model the call-profile link coming up or a dropout.
private final class HeadsetInputDouble: AudioQueueInput {
    var transportType: UInt32? { kAudioDeviceTransportTypeBluetooth }
    private var receive: ((UnsafeBufferPointer<Int16>) -> Void)?
    private var callbackQueue: DispatchQueue?
    private(set) var opened: String?
    private(set) var disposed = false

    func open(microphoneUID: String, callbackQueue: DispatchQueue,
              receive: @escaping (UnsafeBufferPointer<Int16>) -> Void, failed: @escaping (Error) -> Void) throws {
        opened = microphoneUID
        self.callbackQueue = callbackQueue
        self.receive = receive
    }
    func start() throws {}
    func stop(immediately: Bool) throws {}
    func isRunning() throws -> Bool { !disposed }
    func dispose() { disposed = true }
    func send(_ value: Int16) {
        let samples = [Int16](repeating: value, count: FrameConverter.frame)
        callbackQueue?.sync { samples.withUnsafeBufferPointer { receive?($0) } }
    }
}

private final class ComputerInputDouble: RecordingSource {
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?
    var output: AsyncStream<[Int16]>.Continuation?
    func start() throws -> AsyncStream<[Int16]> {
        let (stream, output) = AsyncStream<[Int16]>.makeStream()
        self.output = output
        return stream
    }
    func send(_ value: Int16) { output?.yield([Int16](repeating: value, count: FrameConverter.frame)) }
    func stop() { output?.finish() }
}

/// The tail timer is fired explicitly so key-up ordering is exact.
private final class TailTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [() -> Void] = []
    var count: Int { lock.withLock { work.count } }
    func add(_ delay: TimeInterval, _ fire: @escaping () -> Void) { lock.withLock { work.append(fire) } }
    func fire() { let all = lock.withLock { let all = work; work = []; return all }; all.forEach { $0() } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

@MainActor
final class DictationHeadsetTests: XCTestCase {
    private let builtIn = Microphone(id: "builtin", name: "MacBook 麦克风", deviceID: 1, transport: kAudioDeviceTransportTypeBuiltIn)
    private let airPods = Microphone(id: "airpods", name: "AirPods", deviceID: 2, transport: kAudioDeviceTransportTypeBluetooth)
    private var inputs: [HeadsetInputDouble] = []
    private let timers = TailTimers()
    private let clock = Clock()

    private func makeHeadset(_ available: @escaping () -> [Microphone]) -> HeadsetMicrophone {
        HeadsetMicrophone(microphones: available, makeInput: { [unowned self] in
            let input = HeadsetInputDouble(); inputs.append(input); return input
        }, now: { [clock] in clock.now }, schedule: timers.add, lookback: 2, automaticallyMonitor: false)
    }

    private func makeSession(_ headset: HeadsetMicrophone, available: @escaping () -> [Microphone],
                             computer: @escaping () -> RecordingSource) throws -> (DictationSession, () -> [DictationSession.Result]) {
        let suite = "OpenVoice-Headset-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: MicrophonePreference.headsetKey)
        let recorder = Recorder(defaults: defaults) { preference in
            RoutedRecordingSource(preference: preference, microphones: available, makeSource: { microphone in
                microphone.isHeadset ? headset.tap(for: microphone) ?? computer() : computer()
            }, automaticallyMonitor: false)
        }
        let capture = DictationCapture(start: recorder.start, stop: recorder.stop)
        let session = DictationSession(startCapture: capture.take, stopCapture: capture.stop,
                                      captureFailure: { recorder.failureSnapshot }, makeEngine: { _ in HeadsetTextEngine() })
        var results: [DictationSession.Result] = []
        session.onFinish = { results.append($0) }
        return (session, { results })
    }

    /// The link comes up once while headset mode is on. Speech begun just before the
    /// key press, and audio still in flight at key-up, are both kept; later audio is not.
    func testResidentHeadsetKeepsFirstWordAndBluetoothTailExactly() async throws {
        let headset = makeHeadset { [self.builtIn, self.airPods] }
        headset.setEnabled(true)
        headset.devicesChanged()
        XCTAssertEqual(inputs.first?.opened, "airpods")
        XCTAssertEqual(headset.currentState, .connecting)
        for _ in 0..<3 { inputs[0].send(0) }
        headset.devicesChanged()
        XCTAssertEqual(headset.currentState, .connecting, "Digital zeros are the link coming up, not speech")
        inputs[0].send(101)
        headset.devicesChanged()
        XCTAssertEqual(headset.currentState, .live)

        let (session, results) = try makeSession(headset, available: { [self.builtIn, self.airPods] }) {
            XCTFail("A live resident headset must not fall back"); return ComputerInputDouble()
        }
        try session.start(channel: .wetype)
        inputs[0].send(102)
        try await parityEventually { session.text == "开头中间" }
        session.end()
        try await parityEventually { timers.count == 1 }
        inputs[0].send(103)
        headset.devicesChanged()
        timers.fire()
        headset.devicesChanged()
        inputs[0].send(104)
        try await parityEventually { results().count == 1 }
        XCTAssertEqual(results(), [.init(text: "开头中间结尾。", error: nil, sendsReturn: false)])
        XCTAssertEqual(inputs.count, 1, "Recordings never reopen the headset")
        XCTAssertFalse(inputs[0].disposed)
    }

    func testHeadsetDisconnectFallsBackToComputerMicrophoneKeepingCapturedWords() async throws {
        var available = [builtIn, airPods]
        let headset = makeHeadset { available }
        headset.setEnabled(true)
        headset.devicesChanged()
        inputs[0].send(1)
        let computer = ComputerInputDouble()
        var computerOpens = 0
        let (session, results) = try makeSession(headset, available: { available }) {
            computerOpens += 1; return computer
        }
        try session.start(channel: .wetype)
        inputs[0].send(101)
        try await parityEventually { session.text == "开头" }
        available = [builtIn]
        headset.devicesChanged()
        XCTAssertTrue(inputs[0].disposed)
        XCTAssertEqual(headset.currentState, .waiting)
        try await parityEventually { computerOpens == 1 && computer.output != nil }
        XCTAssertTrue(session.isRecording)
        computer.send(102)
        try await parityEventually { session.text == "开头中间" }
        session.end()
        try await parityEventually { results().count == 1 }
        XCTAssertEqual(results(), [.init(text: "开头中间", error: nil, sendsReturn: false)])
    }

    func testLeavingHeadsetModeDrainsTheLiveRecordingBeforeReleasingTheHeadset() async throws {
        let headset = makeHeadset { [self.builtIn, self.airPods] }
        headset.setEnabled(true)
        headset.devicesChanged()
        inputs[0].send(1)
        let (session, results) = try makeSession(headset, available: { [self.builtIn, self.airPods] }) {
            ComputerInputDouble()
        }
        try session.start(channel: .wetype)
        headset.setEnabled(false)
        headset.devicesChanged()
        XCTAssertFalse(inputs[0].disposed, "A live recording keeps its input")
        inputs[0].send(101)
        try await parityEventually { session.text == "开头" }
        session.end()
        try await parityEventually { timers.count == 1 }
        timers.fire()
        headset.devicesChanged()
        try await parityEventually { results().count == 1 }
        XCTAssertEqual(results().first?.text, "开头")
        XCTAssertTrue(inputs[0].disposed)
        XCTAssertEqual(headset.currentState, .off)
        XCTAssertNil(headset.tap(for: airPods))
    }

    func testCallbackStallReopensWithBackoffAndLockReleasesTheMicrophone() throws {
        let headset = makeHeadset { [self.builtIn, self.airPods] }
        headset.setEnabled(true)
        headset.devicesChanged()
        inputs[0].send(1)
        headset.devicesChanged()
        clock.now = 1.5
        headset.checkHealth()
        XCTAssertFalse(inputs[0].disposed, "Callbacks of real zeros or sound are not a stall")
        clock.now = 3
        headset.checkHealth()
        XCTAssertTrue(inputs[0].disposed)
        XCTAssertEqual(inputs.count, 1, "Reopening waits for the backoff")
        clock.now = 4.5
        headset.checkHealth()
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(headset.currentState, .connecting)
        headset.setSuspended(true)
        headset.devicesChanged()
        XCTAssertTrue(inputs[1].disposed)
        XCTAssertNil(headset.tap(for: airPods))
        headset.setSuspended(false)
        headset.devicesChanged()
        XCTAssertEqual(inputs.count, 3)
        inputs[2].send(1)
        headset.devicesChanged()
        XCTAssertNotNil(headset.tap(for: airPods))
        XCTAssertNil(headset.tap(for: builtIn))
    }

    func testMenuTogglesHeadsetModeAndShowsItsState() throws {
        let suite = "OpenVoice-HeadsetMenu-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let headset = makeHeadset { [self.builtIn, self.airPods] }
        let app = AppDelegate(capture: DictationCapture(start: { AsyncStream { $0.finish() } }, stop: {}),
                              defaults: defaults, headset: headset)
        let menu = NSMenu()
        app.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first { $0.title == "耳机模式" }?.state, .off)
        XCTAssertTrue(inputs.isEmpty, "Default computer mode never opens the headset")
        app.toggleHeadsetMode()
        headset.devicesChanged()
        XCTAssertTrue(MicrophonePreference.current(in: defaults).headset)
        XCTAssertEqual(inputs.first?.opened, "airpods")
        app.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first { $0.title == "耳机模式" }?.state, .on)
        XCTAssertNotNil(menu.items.first { $0.title == "耳机麦克风连接中…" })
        app.toggleHeadsetMode()
        headset.devicesChanged()
        XCTAssertFalse(MicrophonePreference.current(in: defaults).headset)
        XCTAssertTrue(inputs[0].disposed)
    }
}

@MainActor
private final class HeadsetTextEngine: ASREngine {
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        var text = ""
        for await frame in audio {
            switch frame[0] {
            case 0, 1: continue
            case 101: text += "开头"
            case 102: text += "中间"
            case 103: text += "结尾。"
            default: text += "错误"
            }
            partial(text)
        }
        return text
    }
}
