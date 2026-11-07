import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog

/// CoreAudio 输入设备；UID 存设置里，拔掉后自动回退系统默认
struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID

    static var selectedUID: String { UserDefaults.standard.string(forKey: "micUID") ?? "" }

    static func all() -> [Microphone] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("CADefaultDeviceAggregate"), !uid.hasPrefix("VPAUAggregateAudioDevice"),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Microphone(id: uid, name: name, deviceID: id)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// 任意输入格式 → 16kHz/mono/Int16，按 20ms（320 样本）切帧
final class FrameConverter {
    static let frame = 320
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter
    private var pending = AudioFrameBuffer()
    private var output: AVAudioPCMBuffer?

    init(from input: AVAudioFormat, firstChannelOnly: Bool = false) throws {
        guard let c = AVAudioConverter(from: input, to: Self.format) else { throw ASRError("不支持的音频格式") }
        if firstChannelOnly { c.channelMap = [0] }
        converter = c
    }

    func push(_ buffer: AVAudioPCMBuffer) -> [[Int16]] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64
        let out: AVAudioPCMBuffer
        if let cached = output, cached.frameCapacity >= capacity { out = cached }
        else {
            guard let allocated = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
            output = allocated
            out = allocated
        }
        out.frameLength = 0
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return pending.push(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }

    /// 不足一帧的尾巴补零
    func flush() -> [Int16]? {
        pending.flush()
    }
}

protocol RecordingSource: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start() throws -> AsyncStream<[Int16]>
    func stop()
}

/// Each recording owns its source. A setting change never replaces live capture
/// or lets a callback from a stopped source write into the next recording.
final class Recorder {
    // Preserve existing users' opt-in when replacing echo processing with muting.
    static let mutePlaybackKey = "suppressPlayback"
    private let defaults: UserDefaults
    private let makeSource: (String) -> RecordingSource
    private let silencer: PlaybackSilencer
    private var source: RecordingSource?
    private var muteLease: PlaybackMuteLease?
    private final class Failure {
        private let lock = NSLock()
        private var error: String?
        func set(_ error: Error) { lock.lock(); self.error = error.localizedDescription; lock.unlock() }
        var message: String? { lock.lock(); defer { lock.unlock() }; return error }
    }
    private var failure = Failure()
    var onLevel: ((Float) -> Void)?
    var failureSnapshot: () -> String? {
        let failure = failure
        return { failure.message }
    }

    init(defaults: UserDefaults = .standard, silencer: PlaybackSilencer = .shared,
         makeSource: @escaping (String) -> RecordingSource = { AudioQueueSource(microphoneUID: $0) }) {
        self.defaults = defaults
        self.silencer = silencer
        self.makeSource = makeSource
    }

    func start() throws -> AsyncStream<[Int16]> {
        guard source == nil else { throw ASRError("录音已开始") }
        let input = makeSource(defaults.string(forKey: "micUID") ?? "")
        input.onLevel = onLevel
        let failure = Failure()
        self.failure = failure
        let reportFailure: (Error) -> Void = { [weak self, weak input] error in
            failure.set(error)
            DispatchQueue.main.async {
                guard let self, let input, self.source === input else { return }
                self.stop()
            }
        }
        input.onFailure = reportFailure
        var lease: PlaybackMuteLease?
        do {
            if defaults.bool(forKey: Self.mutePlaybackKey) {
                lease = try silencer.acquire(onFailure: reportFailure)
            }
            let stream = try input.start()
            source = input
            muteLease = lease
            return stream
        } catch {
            input.stop()
            lease?.finish()
            throw error
        }
    }

    func stop() {
        let input = source, lease = muteLease
        source = nil
        muteLease = nil
        input?.stop()
        // Audio is restored at the capture boundary, never after ASR finalization.
        lease?.finish()
    }

    deinit { source?.stop(); muteLease?.finish() }

    /// RMS → dBFS，-50dB 以下视为静音，-10dB 封顶
    static func level(_ frame: [Int16]) -> Float {
        let sum = frame.reduce(Float(0)) { $0 + Float($1) * Float($1) }
        let rms = (sum / Float(frame.count)).squareRoot() / 32768
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }
}

/// Low-cost capture for both normal recording and recording with output muted.
final class AudioQueueSource: RecordingSource {
    private static let log = Logger(subsystem: "do.j3.openvoice", category: "CaptureTiming")
    private let callbackQueue = DispatchQueue(label: "openvoice.recorder")
    private let microphoneUID: String
    private let input: AudioQueueInput
    private let drainTimeout: TimeInterval
    private var drainTask: Task<Void, Never>?
    private var active = false
    private var stopping = false
    private var began: TimeInterval = 0
    private var sampleCount = 0
    private var pending = AudioFrameBuffer()
    private var continuation: AsyncStream<[Int16]>.Continuation?
    /// 每 20ms 帧的音量（0...1），在采集队列回调
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(microphoneUID: String, input: AudioQueueInput = SystemAudioQueueInput(), drainTimeout: TimeInterval = 0.75) {
        self.microphoneUID = microphoneUID
        self.input = input
        self.drainTimeout = drainTimeout
    }

    func start() throws -> AsyncStream<[Int16]> {
        let (stream, cont) = AsyncStream<[Int16]>.makeStream()
        guard !active else { throw ASRError("录音已开始") }
        began = ProcessInfo.processInfo.systemUptime
        callbackQueue.sync {
            pending = AudioFrameBuffer()
            continuation = cont
            sampleCount = 0
        }
        do {
            try input.open(microphoneUID: microphoneUID, callbackQueue: callbackQueue, receive: { [weak self] samples in
                guard let self, let continuation = self.continuation, !samples.isEmpty else { return }
                if self.sampleCount == 0 {
                    Self.log.notice("first-audio ms=\(Int((ProcessInfo.processInfo.systemUptime - self.began) * 1000))")
                }
                self.sampleCount += samples.count
                for frame in self.pending.push(samples) {
                    continuation.yield(frame)
                    self.onLevel?(Recorder.level(frame))
                }
            }, failed: { [weak self] error in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active else { return }
                    self.onFailure?(error)
                    self.stop()
                }
            })
            try input.start()
            active = true
            stopping = false
        } catch {
            input.dispose()
            callbackQueue.sync { continuation?.finish(); continuation = nil }
            throw error
        }
        return stream
    }

    func stop() {
        guard active, !stopping else { return }
        stopping = true
        // The old source may still deliver audio while the next HUD is live.
        callbackQueue.sync { onLevel = nil }
        // Keep the original immediate stop for built-in, wired and unknown inputs.
        // Merely using AirPods for playback must not add a capture delay.
        let transport = input.transportType
        guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else {
            finish()
            return
        }
        do { try input.stop(immediately: false) }
        catch { onFailure?(error); finish(); return }
        // Stop accepting new buffers, but keep this source alive while Core Audio
        // fills its queued buffers. Bluetooth audio can arrive after key-up.
        // A new Recorder capture gets a different source and frame buffer.
        drainTask = Task { @MainActor [self] in
            let deadline = ProcessInfo.processInfo.systemUptime + drainTimeout
            do {
                while try input.isRunning() {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw ASRError("麦克风尾音读取超时，请检查蓝牙连接后重试")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch { onFailure?(error) }
            finish()
        }
    }

    private func finish() {
        // All callbacks must finish before the last sub-frame is padded or the
        // stream ends. Wired inputs stop immediately; Bluetooth reaches this after
        // draining, or as a bounded failure fallback.
        do { try input.stop(immediately: true) } catch { onFailure?(error) }
        callbackQueue.sync {
            if let tail = pending.flush() { continuation?.yield(tail) }
            pending = AudioFrameBuffer()
            continuation?.finish()
            continuation = nil
            Self.log.notice("stopped samples=\(self.sampleCount)")
        }
        input.dispose()
        active = false
        drainTask = nil
    }

    deinit { input.dispose() }
}

/// 调试用：读音频文件，按实时节奏喂帧
func fileFrames(_ url: URL, realtime: Bool) throws -> AsyncStream<[Int16]> {
    let file = try AVAudioFile(forReading: url)
    let conv = try FrameConverter(from: file.processingFormat)
    var frames: [[Int16]] = []
    while file.framePosition < file.length {
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
        try file.read(into: buf)
        frames += conv.push(buf)
    }
    if let tail = conv.flush() { frames.append(tail) }
    return AsyncStream { cont in
        Task {
            for f in frames {
                cont.yield(f)
                if realtime { try? await Task.sleep(for: .milliseconds(20)) }
            }
            cont.finish()
        }
    }
}

/// Pad 200ms of silence before live speech, then emit at most one frame per 20ms.
/// The source stream continues buffering while an engine completes its handshake,
/// so the first spoken frames are not discarded.
func withLeadingSilence(_ audio: AsyncStream<[Int16]>, realtime: Bool = true) -> AsyncStream<[Int16]> {
    AsyncStream { cont in
        let task = Task {
            var next = Date()
            func emit(_ frame: [Int16]) async -> Bool {
                let delay = next.timeIntervalSinceNow
                if realtime, delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                else { next = Date() }
                cont.yield(frame)
                next = next.addingTimeInterval(0.02)
                return !Task.isCancelled
            }

            for _ in 0..<10 {
                guard await emit([Int16](repeating: 0, count: FrameConverter.frame)) else {
                    cont.finish()
                    return
                }
            }
            for await frame in audio {
                guard await emit(frame) else {
                    cont.finish()
                    return
                }
            }
            cont.finish()
        }
        cont.onTermination = { _ in task.cancel() }
    }
}
