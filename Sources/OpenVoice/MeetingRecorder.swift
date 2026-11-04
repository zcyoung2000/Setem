import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Timestamped 20 ms buckets. Both SCStream outputs use the host clock; a delayed source
/// must not shift all subsequent speech or make the faster source run twice as fast.
struct MeetingAudioMixer {
    private var buckets: [Int: [Int32]] = [:]
    private(set) var cursor = 0
    private(set) var latest = 0

    mutating func add(_ frame: [Int16], at index: Int) throws {
        guard index >= 0 else { return } // samples predating the capture start
        guard index >= cursor else { throw ASRError("收音数据延迟过大，会议已停止以避免静默漏录") }
        var mixed = buckets[index] ?? [Int32](repeating: 0, count: FrameConverter.frame)
        for i in frame.indices { mixed[i] += Int32(frame[i]) }
        buckets[index] = mixed
        latest = max(latest, index + 1)
    }

    mutating func drain(until end: Int) -> [[Int16]] {
        guard end > cursor else { return [] }
        var frames: [[Int16]] = []
        for index in cursor..<end {
            let mixed = buckets.removeValue(forKey: index)
            frames.append(mixed?.map { Int16(clamping: $0) } ?? [Int16](repeating: 0, count: FrameConverter.frame))
        }
        cursor = end
        return frames
    }
}

/// Audio-only ScreenCaptureKit stream: system audio + the selected microphone.
/// No screen output is registered and no screen images are persisted.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "openvoice.meeting.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncThrowingStream<[Int16], Error>.Continuation?
    private var mixer = MeetingAudioMixer()
    private var converters: [SCStreamOutputType: FrameConverter] = [:]
    private var formats: [SCStreamOutputType: AVAudioFormat] = [:]
    private var nextIndex: [SCStreamOutputType: Int] = [:]
    private var origin: Double = 0
    private var lastMicrophone = Date()
    private var failed = false
    @MainActor private var stopTask: Task<Void, Never>?

    @MainActor
    func start() async throws -> AsyncThrowingStream<[Int16], Error> {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard authorized else { throw ASRError("请在系统设置 → 隐私与安全性 → 麦克风中允许 OpenVoice") }
        try Task.checkCancellation()

        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw ASRError("无法收录电脑声音，请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 OpenVoice：\(error.localizedDescription)") }
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw ASRError("未找到可用屏幕，无法启动电脑声音录制") }
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.capturesAudio = true
        config.captureMicrophone = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        let uid = Microphone.selectedUID
        if !uid.isEmpty {
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            guard devices.contains(where: { $0.uniqueID == uid }) else {
                throw ASRError("所选麦克风已断开，请在设置中重新选择麦克风")
            }
            config.microphoneCaptureDeviceID = uid
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        let (frames, cont) = AsyncThrowingStream<[Int16], Error>.makeStream()
        queue.sync {
            continuation = cont
            origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            lastMicrophone = Date()
            failed = false
        }
        stream = capture
        do { try await capture.startCapture() }
        catch {
            stream = nil
            queue.sync { continuation?.finish(throwing: error); continuation = nil }
            throw error
        }
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
        return frames
    }

    @MainActor
    func stop() async {
        if let stopTask { await stopTask.value; return }
        let task = Task {
            if let stream {
                do { try await stream.stopCapture() }
                catch { queue.sync { fail(error) } }
            }
            stream = nil
            queue.sync {
                timer?.cancel()
                timer = nil
                // The converters retain a sub-frame tail; include it even on a quick stop.
                for (type, converter) in converters {
                    if let tail = converter.flush(), let index = nextIndex[type] {
                        do { try mixer.add(tail, at: index) } catch { fail(error) }
                    }
                }
                for frame in mixer.drain(until: mixer.latest) { continuation?.yield(frame) }
                continuation?.finish()
                continuation = nil
            }
        }
        stopTask = task
        await task.value
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.fail(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !failed, continuation != nil, type == .audio || type == .microphone,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            guard let description = sampleBuffer.formatDescription else { throw ASRError("会议音频格式无效") }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else {
                throw ASRError("会议音频格式无效")
            }
            buffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
            let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(sampleBuffer.numSamples), into: buffer.mutableAudioBufferList)
            guard result == noErr else { throw ASRError("会议音频读取失败 \(result)") }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard timestamp.isFinite else { throw ASRError("会议音频时间戳无效") }
            let index = Int(((timestamp - origin) / 0.02).rounded())
            if formats[type] != format {
                if let old = converters[type], let tail = old.flush(), let previous = nextIndex[type] {
                    try mixer.add(tail, at: previous)
                }
                converters[type] = try FrameConverter(from: format)
                formats[type] = format
                nextIndex[type] = index
            }
            // Preserve real gaps (e.g. muted system output), rather than concatenating them away.
            if let next = nextIndex[type], index - next > 3 { nextIndex[type] = index }
            if type == .microphone { lastMicrophone = Date() }
            for frame in converters[type]!.push(buffer) {
                let next = nextIndex[type] ?? index
                try mixer.add(frame, at: next)
                nextIndex[type] = next + 1
            }
        } catch { fail(error) }
    }

    private func tick() {
        guard !failed else { return }
        // Allow 400 ms of source jitter before mixing; silence from either source is valid.
        let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - origin - 0.4
        let end = max(0, Int(elapsed / 0.02))
        // System audio can stop emitting packets while idle. Flush its sub-frame tail
        // before that timestamp is committed as silence, rather than losing it at stop.
        for (type, converter) in converters {
            if let index = nextIndex[type], index < end, let tail = converter.flush() {
                do {
                    try mixer.add(tail, at: index)
                    nextIndex[type] = index + 1
                } catch { fail(error); return }
            }
        }
        for frame in mixer.drain(until: end) { continuation?.yield(frame) }
        if Date().timeIntervalSince(lastMicrophone) > 5 {
            fail(ASRError("麦克风音频已中断，请检查输入设备后重新开始会议"))
        }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        timer?.cancel()
        timer = nil
        for (type, converter) in converters {
            if let tail = converter.flush(), let index = nextIndex[type] { try? mixer.add(tail, at: index) }
        }
        for frame in mixer.drain(until: mixer.latest) { continuation?.yield(frame) }
        continuation?.finish(throwing: error)
        continuation = nil
    }
}
