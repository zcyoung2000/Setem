import AVFoundation
import AudioToolbox
import CoreAudio

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
    func start() throws -> AsyncStream<[Int16]>
    func stop()
}

/// Each recording owns its source. A setting change never replaces live capture
/// or lets a callback from a stopped source write into the next recording.
final class Recorder {
    static let suppressPlaybackKey = "suppressPlayback"
    private let defaults: UserDefaults
    private let makeSource: (Bool, String) -> RecordingSource
    private var source: RecordingSource?
    private static let hardwareQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "openvoice.recorder.hardware"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    var onLevel: ((Float) -> Void)?
    var onReady: (() -> Void)?
    var isPreparing: Bool { (source as? DeferredRecordingSource)?.preparation.isPreparing ?? false }
    var failureSnapshot: () -> String? {
        let state = (source as? DeferredRecordingSource)?.preparation
        return { state?.failure }
    }

    init(defaults: UserDefaults = .standard,
         makeSource: @escaping (Bool, String) -> RecordingSource = { suppress, uid in
             if suppress { return VoiceProcessingSource(microphoneUID: uid) }
             return AudioQueueSource(microphoneUID: uid)
         }) {
        self.defaults = defaults
        self.makeSource = makeSource
    }

    func start() throws -> AsyncStream<[Int16]> {
        guard source == nil else { throw ASRError("录音已开始") }
        let suppress = defaults.bool(forKey: Self.suppressPlaybackKey)
        let raw = makeSource(suppress, defaults.string(forKey: "micUID") ?? "")
        let input: RecordingSource
        if suppress || Self.hardwareQueue.operationCount > 0 {
            let deferred = DeferredRecordingSource(raw, queue: Self.hardwareQueue)
            deferred.onReady = { [weak self, weak deferred] in
                DispatchQueue.main.async { [weak self, weak deferred] in
                    guard let self, let deferred, self.source === deferred else { return }
                    self.onReady?()
                }
            }
            input = deferred
        } else { input = raw }
        input.onLevel = onLevel
        do {
            let stream = try input.start()
            source = input
            return stream
        } catch {
            input.stop()
            throw error
        }
    }

    func stop() {
        let input = source
        source = nil
        input?.stop()
    }

    deinit { source?.stop() }

    /// RMS → dBFS，-50dB 以下视为静音，-10dB 封顶
    static func level(_ frame: [Int16]) -> Float {
        let sum = frame.reduce(Float(0)) { $0 + Float($1) * Float($1) }
        let rms = (sum / Float(frame.count)).squareRoot() / 32768
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }
}

/// The unchanged low-cost path when echo suppression is off.
final class AudioQueueSource: RecordingSource {
    private let callbackQueue = DispatchQueue(label: "openvoice.recorder")
    private let microphoneUID: String
    private var queue: AudioQueueRef?
    private var pending = AudioFrameBuffer()
    private var continuation: AsyncStream<[Int16]>.Continuation?
    /// 每 20ms 帧的音量（0...1），在采集队列回调
    var onLevel: ((Float) -> Void)?

    init(microphoneUID: String) { self.microphoneUID = microphoneUID }

    func start() throws -> AsyncStream<[Int16]> {
        let (stream, cont) = AsyncStream<[Int16]>.makeStream()
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var q: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&q, &format, 0, callbackQueue) { [weak self] q, buffer, _, _, _ in
            guard let self, let continuation = self.continuation else { return }
            let count = Int(buffer.pointee.mAudioDataByteSize) / 2
            let samples = UnsafeBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self), count: count)
            for frame in self.pending.push(samples) {
                continuation.yield(frame)
                self.onLevel?(Recorder.level(frame))
            }
            AudioQueueEnqueueBuffer(q, buffer, 0, nil)
        }
        guard status == noErr, let q else { throw ASRError("麦克风打开失败 \(status)") }
        queue = q
        let uid = microphoneUID
        if !uid.isEmpty, Microphone.all().contains(where: { $0.id == uid }) {
            var cf = uid as CFString
            AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &cf, UInt32(MemoryLayout<CFString>.size))
        }
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(q, UInt32(FrameConverter.frame * 2 * 2), &buffer)
            if let buffer { AudioQueueEnqueueBuffer(q, buffer, 0, nil) }
        }
        callbackQueue.sync {
            pending = AudioFrameBuffer()
            continuation = cont
        }
        let started = AudioQueueStart(q, nil)
        guard started == noErr else {
            throw ASRError("麦克风启动失败 \(started)")
        }
        return stream
    }

    func stop() {
        guard let q = queue else { return }
        queue = nil
        AudioQueueStop(q, true)
        callbackQueue.sync {
            if let tail = pending.flush() { continuation?.yield(tail) }
            pending = AudioFrameBuffer()
            continuation?.finish()
            continuation = nil
        }
        AudioQueueDispose(q, true)
    }
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
func withLeadingSilence(_ audio: AsyncStream<[Int16]>) -> AsyncStream<[Int16]> {
    AsyncStream { cont in
        let task = Task {
            var next = Date()
            func emit(_ frame: [Int16]) async -> Bool {
                let delay = next.timeIntervalSinceNow
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
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
