import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// A recording owns this lease, including its Bluetooth tail drain. Releasing an
/// older lease never closes the output queue belonging to a newer recording.
final class AudioRouteLease {
    private let lock = NSLock()
    private var release: (() -> Void)?
    init(_ release: @escaping () -> Void) { self.release = release }
    func finish() {
        lock.lock()
        let action = release
        release = nil
        lock.unlock()
        action?()
    }
    deinit { finish() }
}

/// Best-effort, recording-only output activity on the selected headset. It does
/// not change the system default, output volume, or any other app's playback.
enum AirPodsAudioHold {
    private static let log = Logger(subsystem: "do.j3.openvoice", category: "AirPodsRouting")

    static func acquire(_ microphone: Microphone) -> AudioRouteLease? {
        guard microphone.isAirPods, let uid = outputUID(for: microphone) else { return nil }
        do {
            let output = try SilentHeadsetOutput(uid: uid)
            return AudioRouteLease { output.stop() }
        } catch {
            log.notice("silent-output-unavailable code=\((error as NSError).code)")
            return nil
        }
    }

    private static func outputUID(for microphone: Microphone) -> String? {
        func hasOutput(_ id: AudioDeviceID) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
        }
        func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioDeviceID] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var result = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return [] }
            return result
        }
        // Some Core Audio drivers expose input/output as one device, others as
        // related objects. Resolve both without writing default-device settings.
        if hasOutput(microphone.deviceID) { return microphone.id }
        for id in ids(microphone.deviceID, kAudioDevicePropertyRelatedDevices) where hasOutput(id) {
            if let uid = Microphone.string(id, kAudioDevicePropertyDeviceUID) { return uid }
        }
        // Older Bluetooth drivers encode the paired endpoints in the UID.
        guard let separator = microphone.id.lastIndex(of: ":") else { return nil }
        let prefix = microphone.id[..<separator]
        for id in ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) where hasOutput(id) {
            guard let uid = Microphone.string(id, kAudioDevicePropertyDeviceUID),
                  let end = uid.lastIndex(of: ":"), uid[..<end] == prefix else { continue }
            return uid
        }
        return nil
    }
}

private final class SilentHeadsetOutput {
    private let callbacks = DispatchQueue(label: "openvoice.airpods-output")
    private var queue: AudioQueueRef?
    // Read/written only on callbacks, including shutdown.
    private var active = false

    init(uid: String) throws {
        var format = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var output: AudioQueueRef?
        func check(_ status: OSStatus) throws {
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        try check(AudioQueueNewOutputWithDispatchQueue(&output, &format, 0, callbacks) { [weak self] q, buffer in
            guard self?.active == true else { return }
            _ = AudioQueueEnqueueBuffer(q, buffer, 0, nil)
        })
        guard let output else { throw ASRError("耳机输出不可用") }
        queue = output
        do {
            let device = uid as CFString
            var reference = Unmanaged.passUnretained(device)
            try withExtendedLifetime(device) {
                try check(AudioQueueSetProperty(output, kAudioQueueProperty_CurrentDevice, &reference,
                                                UInt32(MemoryLayout.size(ofValue: reference))))
            }
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(output, 1280, &buffer))
                guard let buffer else { throw ASRError("耳机输出缓冲不可用") }
                memset(buffer.pointee.mAudioData, 0, 1280)
                buffer.pointee.mAudioDataByteSize = 1280
                try check(AudioQueueEnqueueBuffer(output, buffer, 0, nil))
            }
            callbacks.sync { active = true }
            try check(AudioQueueStart(output, nil))
        } catch { stop(); throw error }
    }

    func stop() {
        guard let queue else { return }
        self.queue = nil
        callbacks.sync { active = false }
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
    }
    deinit { stop() }
}
