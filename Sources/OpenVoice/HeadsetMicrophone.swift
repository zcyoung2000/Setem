import CoreAudio
import Foundation
import OSLog

/// Keeps one Bluetooth headset input open while headset mode is on, as a call does.
/// Opening a headset microphone switches it to its call profile; until the link is
/// up, Core Audio delivers about one second of digital zeros. Paying that once per
/// connection, instead of per recording, keeps the first words. Each recording is a
/// tap with a short look-back and, after key-up, a tail for audio still in flight.
// Mutable state is confined to queue. Native callbacks only copy samples and enqueue.
final class HeadsetMicrophone: @unchecked Sendable {
    enum State: Equatable { case off, waiting, connecting, live }
    static let shared = HeadsetMicrophone()
    private static let log = Logger(subsystem: "do.j3.openvoice", category: "HeadsetMic")
    private static let backoff: [TimeInterval] = [1, 2, 5, 10, 30]

    private let queue = DispatchQueue(label: "openvoice.headset")
    private let nativeQueue = DispatchQueue(label: "openvoice.headset-input")
    private let microphones: () -> [Microphone]
    private let makeInput: () -> AudioQueueInput
    private let now: () -> TimeInterval
    private let schedule: ((TimeInterval, @escaping () -> Void) -> Void)?
    private let lookback: Int
    private let tail: TimeInterval
    private let automaticallyMonitor: Bool
    private var enabled = false
    private var suspended = false
    private var device: Microphone?
    private var input: AudioQueueInput?
    private var generation = 0
    private var pending = AudioFrameBuffer()
    private var recent = FIFOBuffer<[Int16]>()
    private var taps: [ObjectIdentifier: ResidentTap] = [:]
    private var openedAt: TimeInterval = 0
    private var lastCallbackAt: TimeInterval?
    private var lastSoundAt: TimeInterval?
    private var failures = 0
    private var retryAt: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var listener: AudioObjectPropertyListenerBlock?
    private var state = State.off
    /// Delivered on the main queue.
    var onStateChange: ((State) -> Void)?

    init(microphones: @escaping () -> [Microphone] = Microphone.all,
         makeInput: @escaping () -> AudioQueueInput = { SystemAudioQueueInput() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
         lookback: Int = 15, tail: TimeInterval = 0.5, automaticallyMonitor: Bool = true) {
        self.microphones = microphones
        self.makeInput = makeInput
        self.now = now
        self.schedule = schedule
        self.lookback = lookback
        self.tail = tail
        self.automaticallyMonitor = automaticallyMonitor
    }

    var currentState: State { queue.sync { state } }

    /// Recordings already running keep their tap until they end.
    func setEnabled(_ on: Bool) {
        queue.async { [self] in
            guard enabled != on else { return }
            enabled = on
            failures = 0
            retryAt = 0
            Self.log.notice("headset-mode enabled=\(on)")
            reconcile()
        }
    }

    /// Locked or sleeping screens release the microphone and allow system sleep.
    func setSuspended(_ on: Bool) {
        queue.async { [self] in
            guard suspended != on else { return }
            suspended = on
            failures = 0
            retryAt = 0
            reconcile()
        }
    }

    /// A tap on the resident input, or nil when it is not open on this headset.
    func tap(for microphone: Microphone) -> RecordingSource? {
        queue.sync { input != nil && device?.id == microphone.id ? ResidentTap(owner: self) : nil }
    }

    /// Explicit entry points let regressions exercise exact ordering.
    func devicesChanged() { queue.sync { reconcile() } }
    func checkHealth() { queue.sync { check() } }

    // MARK: - Resident input

    private func reconcile() {
        let available = microphones()
        let wanted = enabled && !suspended ? Microphone.headset(in: available) : nil
        if let device, input != nil {
            if wanted?.id == device.id { return }
            let present = available.contains { $0.id == device.id }
            // Leaving headset mode or locking drains live recordings first.
            if present, !taps.isEmpty { return }
            close(error: present ? nil : ASRError("耳机已断开"))
        }
        // Device notifications start the input; polling only runs with a headset present.
        updateMonitoring(listen: enabled && !suspended, poll: wanted != nil || input != nil)
        guard let wanted else {
            setState(enabled ? .waiting : .off)
            return
        }
        guard now() >= retryAt else { return }
        open(wanted)
    }

    private func open(_ microphone: Microphone) {
        generation += 1
        let own = generation
        let input = makeInput()
        pending = AudioFrameBuffer()
        recent = FIFOBuffer()
        lastCallbackAt = nil
        lastSoundAt = nil
        do {
            try input.open(microphoneUID: microphone.id, callbackQueue: nativeQueue, receive: { [weak self] samples in
                let copy = Array(samples)
                self?.queue.async { self?.received(copy, generation: own) }
            }, failed: { [weak self] error in
                self?.queue.async { self?.failed(error, generation: own) }
            })
            try input.start()
        } catch {
            input.dispose()
            delayRetry()
            Self.log.notice("open-failed attempt=\(self.failures) reason=\(error.localizedDescription, privacy: .public)")
            setState(.waiting)
            return
        }
        self.input = input
        device = microphone
        openedAt = now()
        setState(.connecting)
        Self.log.notice("opened input=\(microphone.id, privacy: .private(mask: .hash))")
    }

    private func close(error: Error?) {
        generation += 1
        let input = self.input
        self.input = nil
        device = nil
        try? input?.stop(immediately: true)
        input?.dispose()
        // Recordings fall back through RoutedRecordingSource with their frames kept.
        for tap in Array(taps.values) { end(tap, error: error ?? ASRError("耳机麦克风已关闭")) }
        Self.log.notice("closed failed=\(error != nil)")
    }

    private func delayRetry() {
        failures += 1
        retryAt = now() + Self.backoff[min(failures, Self.backoff.count) - 1]
    }

    private func failed(_ error: Error, generation own: Int) {
        guard own == generation, input != nil else { return }
        delayRetry()
        Self.log.notice("input-failed reason=\(error.localizedDescription, privacy: .public)")
        close(error: error)
        reconcile()
    }

    private func check() {
        let time = now()
        if input != nil {
            // Real zeros still arrive as callbacks; only missing callbacks are a stall.
            let quiet = time - (lastCallbackAt ?? openedAt)
            if quiet >= (lastCallbackAt == nil ? 4 : 2) {
                delayRetry()
                Self.log.notice("stalled ms=\(Int(quiet * 1000))")
                close(error: ASRError("耳机麦克风音频回调已停滞"))
            } else if state == .live, time - (lastSoundAt ?? openedAt) >= 1.5 {
                // The headset link dropped (e.g. taken by a phone) but the device remains.
                setState(.connecting)
            }
        }
        reconcile()
    }

    private func received(_ samples: [Int16], generation own: Int) {
        guard own == generation, input != nil else { return }
        let time = now()
        lastCallbackAt = time
        let frames = samples.withUnsafeBufferPointer { pending.push($0) }
        for frame in frames {
            let sound = frame.contains { $0 != 0 }
            if sound {
                if state != .live {
                    Self.log.notice("live ms=\(Int((time - self.openedAt) * 1000))")
                    failures = 0
                    setState(.live)
                }
                lastSoundAt = time
            }
            recent.append(frame)
            while recent.count > lookback { _ = recent.popFirst() }
            for tap in taps.values { tap.receive(frame, sound: sound) }
        }
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        let callback = onStateChange
        DispatchQueue.main.async { callback?(next) }
    }

    private func updateMonitoring(listen: Bool, poll: Bool) {
        guard automaticallyMonitor else { return }
        if poll, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        } else if !poll, let timer {
            timer.cancel()
            self.timer = nil
        }
        var address = Self.devicesAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        if listen, listener == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reconcile() }
            if AudioObjectAddPropertyListenerBlock(system, &address, queue, listener) == noErr { self.listener = listener }
        } else if !listen, let listener {
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
            self.listener = nil
        }
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - Taps

    fileprivate func attach(_ tap: ResidentTap) throws -> AsyncStream<[Int16]> {
        try queue.sync {
            guard input != nil, tap.output == nil, !tap.ended else { throw ASRError("耳机麦克风未就绪") }
            let (stream, output) = AsyncStream<[Int16]>.makeStream()
            tap.output = output
            // Speech that began just before the key press is already buffered.
            var lookback = recent
            while let frame = lookback.popFirst() { tap.receive(frame, sound: frame.contains { $0 != 0 }) }
            taps[ObjectIdentifier(tap)] = tap
            return stream
        }
    }

    fileprivate func detach(_ tap: ResidentTap, completion: @escaping () -> Void) {
        queue.async { [self] in
            guard taps[ObjectIdentifier(tap)] != nil else { completion(); return }
            tap.completions.append(completion)
            guard !tap.stopping else { return }
            tap.stopping = true
            // Bluetooth delivers the last spoken audio after key-up.
            after(tail) { [weak self] in
                guard let self else { return }
                self.end(tap, error: nil)
                if self.taps.isEmpty { self.reconcile() }
            }
        }
    }

    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        if let schedule { schedule(delay) { [weak self] in self?.queue.async(execute: work) } }
        else { queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    private func end(_ tap: ResidentTap, error: Error?) {
        guard taps.removeValue(forKey: ObjectIdentifier(tap)) != nil else { return }
        let output = tap.output
        tap.output = nil
        tap.ended = true
        let callbacks = tap.completions
        tap.completions.removeAll()
        Self.log.notice("tap-ended frames=\(tap.frames) silent=\(tap.silentFrames) gaps=\(tap.gaps) longestGapMs=\(tap.longestGap * 20) failed=\(error != nil)")
        if let error { tap.onFailure?(error) }
        callbacks.forEach { $0() }
        output?.finish()
    }
}

/// One recording's view of the resident headset input.
// Fields other than the callbacks are confined to the owner's queue.
private final class ResidentTap: RecordingSource, @unchecked Sendable {
    let owner: HeadsetMicrophone
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?
    var output: AsyncStream<[Int16]>.Continuation?
    var stopping = false
    var ended = false
    var completions: [() -> Void] = []
    var frames = 0, silentFrames = 0, gaps = 0, longestGap = 0
    private var run = 0, heard = false

    init(owner: HeadsetMicrophone) { self.owner = owner }

    func start() throws -> AsyncStream<[Int16]> { try owner.attach(self) }
    func stop() { stop(completion: {}) }
    func stop(completion: @escaping () -> Void) { owner.detach(self, completion: completion) }

    /// Exact zeros after the link carried sound are Bluetooth dropouts, logged per recording.
    func receive(_ frame: [Int16], sound: Bool) {
        frames += 1
        if sound {
            if run > 0, heard { gaps += 1; longestGap = max(longestGap, run) }
            run = 0
            heard = true
        } else {
            silentFrames += 1
            run += 1
        }
        output?.yield(frame)
    }
}
