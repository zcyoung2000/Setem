import Foundation
import OSLog

/// Owns one logical capture stream across native input restarts. Recognition and
/// DictationCapture keep their existing ownership and never restart for a route.
// Mutable capture state is confined to queue; callbacks are installed before
// start, as required by RecordingSource. Native readers only enqueue work.
final class RoutedRecordingSource: RecordingSource, @unchecked Sendable {
    private static let log = Logger(subsystem: "do.j3.openvoice", category: "InputRouting")
    private let queue = DispatchQueue(label: "openvoice.input-routing")
    private let preference: MicrophonePreference
    private let microphones: () -> [Microphone]
    private let makeSource: (Microphone) throws -> RecordingSource
    private let now: () -> TimeInterval
    private let automaticallyMonitor: Bool
    private var timer: DispatchSourceTimer?
    private var input: RecordingSource?
    private var pump: Task<Void, Never>?
    private var output: AsyncStream<[Int16]>.Continuation?
    private var microphone: Microphone?
    private var token = UUID()
    private var attempts: [String: Int] = [:]
    private var recoveryError: Error?
    private var terminalError: Error?
    private var running = false
    private var stopping = false
    private var recovering = false
    private var fellBack = false
    private var openedAt: TimeInterval = 0
    private var lastFrameAt: TimeInterval?
    private var samples = 0
    private var nonzero = false
    private var usedHeadset = false
    private let routeLock = NSLock()
    private var stoppedCallbacks: [() -> Void] = []
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(preference: MicrophonePreference, microphones: @escaping () -> [Microphone] = Microphone.all,
         makeSource: @escaping (Microphone) throws -> RecordingSource = RoutedRecordingSource.source,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticallyMonitor: Bool = true) {
        self.preference = preference
        self.microphones = microphones
        self.makeSource = makeSource
        self.now = now
        self.automaticallyMonitor = automaticallyMonitor
    }

    func start() throws -> AsyncStream<[Int16]> {
        try queue.sync {
            guard !running, output == nil else { throw ASRError("录音已开始") }
            let (stream, output) = AsyncStream<[Int16]>.makeStream()
            self.output = output
            running = true
            stopping = false
            attempts = [:]
            recoveryError = nil
            terminalError = nil
            samples = 0
            nonzero = false
            fellBack = false
            routeLock.withLock { usedHeadset = false }
            do { try openNext() }
            catch { finish(error: nil); throw error }
            if automaticallyMonitor {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.check() }
                self.timer = timer
                timer.resume()
            }
            return stream
        }
    }

    /// One owner for Bluetooth input. Opening a second, on-demand queue here would
    /// bypass the resident input's recovery backoff and readiness checks.
    static func source(_ microphone: Microphone) throws -> RecordingSource {
        if microphone.isHeadset {
            guard let tap = HeadsetMicrophone.shared.tap(for: microphone) else { throw ASRError("耳机麦克风暂不可用") }
            return tap
        }
        return AudioQueueSource(microphoneUID: microphone.id)
    }

    private func openNext() throws {
        let available = microphones()
        var candidates: [Microphone] = []
        if preference.headset, !fellBack {
            if let preferred = available.first(where: { $0.id == microphone?.id && $0.isHeadset })
                ?? Microphone.headset(in: available) { candidates.append(preferred) }
        }
        // An unplugged external microphone falls back to built-in, never the system default.
        if let computer = Microphone.computer(preference.computerUID, in: available) { candidates.append(computer) }
        var lastError: Error = recoveryError ?? ASRError("MacBook 内置麦克风不可用，请开盖后重试")
        for candidate in candidates {
            while attempts[candidate.id, default: 0] < 2 {
                attempts[candidate.id, default: 0] += 1
                token = UUID()
                let ownToken = token
                let next: RecordingSource
                do { next = try makeSource(candidate) }
                catch { lastError = error; continue }
                next.onFailure = { [weak self] error in
                    self?.queue.async { [weak self] in
                        guard let self, self.token == ownToken else { return }
                        if error is RecordingSuspended {
                            guard self.running, !self.stopping else { return }
                            self.terminalError = error
                            self.stopInput()
                        } else { self.recover(error) }
                    }
                }
                do {
                    let stream = try next.start()
                    input = next
                    routeLock.withLock { usedHeadset = usedHeadset || next.changesPlaybackRoute }
                    microphone = candidate
                    fellBack = !candidate.isHeadset
                    recovering = false
                    openedAt = now()
                    lastFrameAt = nil
                    Self.log.notice("opened headsetMode=\(self.preference.headset) headset=\(candidate.isHeadset) builtIn=\(candidate.isBuiltIn) input=\(candidate.id, privacy: .private(mask: .hash)) attempt=\(self.attempts[candidate.id, default: 0])")
                    // Keep the logical source alive until its final native tail
                    // is forwarded, even after Recorder releases it at key-up.
                    pump = Task { [self] in
                        for await frame in stream {
                            guard !frame.isEmpty else { continue }
                            self.queue.sync {
                                guard self.running, self.token == ownToken else { return }
                                self.lastFrameAt = self.now()
                                self.samples += frame.count
                                if !self.nonzero { self.nonzero = frame.contains { $0 != 0 } }
                                self.output?.yield(frame)
                                if !self.stopping { self.onLevel?(Recorder.level(frame)) }
                            }
                        }
                        self.queue.async { self.ended(ownToken) }
                    }
                    return
                } catch {
                    lastError = error
                    next.onFailure = nil
                    next.stop()
                }
            }
        }
        throw lastError
    }

    private func recover(_ error: Error) {
        guard running, !stopping, !recovering else { return }
        recovering = true
        recoveryError = error
        Self.log.notice("recover reason=\(error.localizedDescription, privacy: .public) samples=\(self.samples)")
        // Drain this source into the same stream before opening the replacement.
        // Its EOF, not its error callback, drives the replacement exactly once.
        input?.stop()
    }

    private func ended(_ ownToken: UUID) {
        guard running, token == ownToken else { return }
        if let input { routeLock.withLock { usedHeadset = usedHeadset || input.changesPlaybackRoute } }
        input = nil
        pump = nil
        if stopping {
            let error = terminalError ?? (samples > 0 && !nonzero ? ASRError("未收到有效音频，请检查麦克风后重试") : nil)
            finish(error: error)
            return
        }
        if !recovering { recoveryError = ASRError("麦克风输入意外结束") }
        do { try openNext() }
        catch { finish(error: error) }
    }

    /// Injectable clock and explicit check let regressions exercise exact ordering.
    func checkHealth() { queue.sync { check() } }

    private func check() {
        guard running, !stopping, !recovering else { return }
        guard let microphone else { return }
        if !microphones().contains(where: { $0.id == microphone.id }) {
            recover(ASRError("当前麦克风已断开"))
        } else if let lastFrameAt {
            if now() - lastFrameAt >= 5 { recover(ASRError("麦克风音频回调已停滞")) }
        } else if now() - openedAt >= 8 {
            recover(ASRError("麦克风未提供音频"))
        }
    }

    var changesPlaybackRoute: Bool { routeLock.withLock { usedHeadset } }

    func stop() { stop(completion: {}) }

    func stop(completion: @escaping () -> Void) {
        queue.sync {
            guard running else { completion(); return }
            stoppedCallbacks.append(completion)
            stopInput()
        }
    }

    private func stopInput() {
        guard !stopping else { return }
        stopping = true
        timer?.cancel()
        timer = nil
        input?.stop()
    }

    private func finish(error: Error?) {
        running = false
        stopping = true
        recovering = false
        timer?.cancel()
        timer = nil
        input = nil
        if let error { onFailure?(error) }
        Self.log.notice("ended samples=\(self.samples) nonzero=\(self.nonzero) failed=\(error != nil)")
        let callbacks = stoppedCallbacks
        stoppedCallbacks.removeAll()
        callbacks.forEach { $0() }
        output?.finish()
        output = nil
    }

    deinit {
        timer?.cancel()
        input?.onFailure = nil
        input?.stop()
        output?.finish()
        pump?.cancel()
    }
}
