import AudioToolbox
import CoreAudio
import Foundation

/// The native boundary is injectable so delayed Bluetooth buffers and stop
/// notifications can be tested without a microphone or a recognition service.
protocol AudioQueueInput: AnyObject {
    var transportType: UInt32? { get }
    func open(microphoneUID: String, callbackQueue: DispatchQueue,
              receive: @escaping (UnsafeBufferPointer<Int16>) -> Void,
              failed: @escaping (Error) -> Void) throws
    func start() throws
    func stop(immediately: Bool) throws
    func isRunning() throws -> Bool
    func dispose()
}

final class SystemAudioQueueInput: AudioQueueInput {
    private var queue: AudioQueueRef?
    private var callbackQueue: DispatchQueue?
    // Accessed only on callbackQueue, including the transition to draining.
    private var acceptingBuffers = false

    /// Resolve the queue's actual input at stop time. Output headphones and a
    /// previous default input do not determine whether this recording is wireless.
    var transportType: UInt32? {
        guard let queue else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        var device = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        if AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &value, &size) == noErr,
           let value {
            let deviceUID = value.takeRetainedValue()
            var uid = Unmanaged.passUnretained(deviceUID)
            size = UInt32(MemoryLayout.size(ofValue: device))
            _ = withExtendedLifetime(deviceUID) {
                AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout.size(ofValue: uid)), &uid, &size, &device)
            }
        }
        guard device != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: transport))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw ASRError("\(operation)（\(status)）") }
    }

    func open(microphoneUID: String, callbackQueue: DispatchQueue,
              receive: @escaping (UnsafeBufferPointer<Int16>) -> Void,
              failed: @escaping (Error) -> Void) throws {
        guard !microphoneUID.isEmpty else { throw ASRError("必须指定麦克风") }
        self.callbackQueue = callbackQueue
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var q: AudioQueueRef?
        try check(AudioQueueNewInputWithDispatchQueue(&q, &format, 0, callbackQueue) { [weak self] q, buffer, _, _, _ in
            let samples = UnsafeBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self),
                                              count: Int(buffer.pointee.mAudioDataByteSize) / 2)
            receive(samples)
            guard self?.acceptingBuffers == true else { return }
            let status = AudioQueueEnqueueBuffer(q, buffer, 0, nil)
            if status != noErr { failed(ASRError("麦克风音频缓冲失败（\(status)）")) }
        }, "麦克风打开失败")
        guard let q else { throw ASRError("麦克风打开失败") }
        queue = q
        do {
            guard Microphone.all().contains(where: { $0.id == microphoneUID }) else {
                throw ASRError("所选麦克风不可用")
            }
            let deviceUID = microphoneUID as CFString
            var uid = Unmanaged.passUnretained(deviceUID)
            try withExtendedLifetime(deviceUID) {
                try check(AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &uid,
                                                UInt32(MemoryLayout.size(ofValue: uid))), "麦克风选择失败")
            }
        }
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try check(AudioQueueAllocateBuffer(q, UInt32(FrameConverter.frame * 2 * 2), &buffer), "麦克风缓冲分配失败")
            guard let buffer else { throw ASRError("麦克风缓冲分配失败") }
            try check(AudioQueueEnqueueBuffer(q, buffer, 0, nil), "麦克风缓冲提交失败")
        }
    }

    func start() throws {
        guard let queue else { throw ASRError("麦克风未打开") }
        callbackQueue?.sync { acceptingBuffers = true }
        try check(AudioQueueStart(queue, nil), "麦克风启动失败")
    }

    func stop(immediately: Bool) throws {
        guard let queue else { return }
        callbackQueue?.sync { acceptingBuffers = false }
        try check(AudioQueueStop(queue, immediately), "麦克风停止失败")
    }

    func isRunning() throws -> Bool {
        guard let queue else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size), "麦克风状态读取失败")
        return running != 0
    }

    func dispose() {
        guard let q = queue else { return }
        try? stop(immediately: true)
        AudioQueueDispose(q, true)
        queue = nil
    }

    deinit { dispose() }
}
