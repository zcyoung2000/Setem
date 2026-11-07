import AVFoundation
import Foundation

/// The tap and stop can run on different threads. Finishing atomically flushes
/// the sub-frame tail; late tap callbacks belong only to this finished sink.
final class VoiceProcessingFrames {
    let stream: AsyncStream<[Int16]>
    private let lock = NSLock()
    private let converter: FrameConverter
    private var output: AsyncStream<[Int16]>.Continuation?
    private let onLevel: ((Float) -> Void)?

    init(format: AVAudioFormat, onLevel: ((Float) -> Void)? = nil) throws {
        // Aggregate-device channels have no speaker downmix layout. The voice
        // processor supplies the processed mic on channel 0; map it explicitly.
        converter = try FrameConverter(from: format, firstChannelOnly: true)
        (stream, output) = AsyncStream<[Int16]>.makeStream()
        self.onLevel = onLevel
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let output else { return }
        for frame in converter.push(buffer) {
            output.yield(frame)
            onLevel?(Recorder.level(frame))
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard let output else { return }
        if let tail = converter.flush() { output.yield(tail) }
        output.finish()
        self.output = nil
    }
}

/// macOS voice processing uses device playback as an acoustic echo reference.
/// The mic is tapped only; it is never connected to speakers for monitoring.
final class VoiceProcessingSource: RecordingSource {
    private let microphoneUID: String
    private var engine: AVAudioEngine?
    private var frames: VoiceProcessingFrames?
    private var hasTap = false
    var onLevel: ((Float) -> Void)?

    init(microphoneUID: String) { self.microphoneUID = microphoneUID }

    func start() throws -> AsyncStream<[Int16]> {
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            let input = engine.inputNode
            // Select this engine's input only; never change the system defaults.
            if let microphone = Microphone.all().first(where: { $0.id == microphoneUID }) {
                try input.auAudioUnit.setDeviceID(microphone.deviceID)
            }
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = false
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: true, duckingLevel: .min)
            let hardware = input.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: hardware.sampleRate, channels: 1, interleaved: false) else {
                throw ASRError("麦克风格式不可用")
            }
            // VoiceProcessingIO requires identical client input/output formats.
            // Keep its output running with silence, without monitoring the mic.
            let mixer = engine.mainMixerNode
            mixer.outputVolume = 0
            engine.connect(mixer, to: engine.outputNode, format: format)
            let frames = try VoiceProcessingFrames(format: format, onLevel: onLevel)
            self.frames = frames
            input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in
                frames.push(buffer)
            }
            hasTap = true
            engine.prepare()
            try engine.start()
            return frames.stream
        } catch {
            stop()
            throw ASRError("回声抑制启动失败，请切换麦克风或关闭“抑制电脑播放声音”：\(error.localizedDescription)")
        }
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0) }
        hasTap = false
        frames?.finish()
        frames = nil
        self.engine = nil
    }

    deinit { stop() }
}
