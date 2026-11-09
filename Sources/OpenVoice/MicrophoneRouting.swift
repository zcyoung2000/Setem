import AudioToolbox
import CoreAudio
import IOKit
import Foundation

// Only these two policies participate in input selection. A mode change applies
// to the next recording; a live capture never upgrades from built-in to AirPods.
enum MicrophoneMode: String, CaseIterable, Identifiable {
    case builtIn, airPodsPreferred
    static let key = "microphoneMode"
    var id: String { rawValue }
    var title: String { self == .builtIn ? "MacBook 内置麦" : "优先使用 AirPods" }
    static func current(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: key) ?? "") ?? .builtIn
    }
    static func migrate(in defaults: UserDefaults, microphones: [Microphone]? = nil) {
        if defaults.object(forKey: key) == nil {
            let old = defaults.string(forKey: "micUID") ?? ""
            let mode: Self = !old.isEmpty && (microphones ?? Microphone.all()).contains { $0.id == old && $0.isAirPods } ? .airPodsPreferred : .builtIn
            defaults.set(mode.rawValue, forKey: key)
        }
        defaults.removeObject(forKey: "micUID")
    }
}

/// Resolve physical inputs by UID; never let a pinned input silently follow the default.
struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID

    var transport: UInt32 = kAudioDeviceTransportTypeUnknown
    var manufacturer: String = ""
    var model: String = ""
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isAirPods: Bool {
        let wireless = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        return wireless && (name.localizedCaseInsensitiveContains("AirPods") || model.localizedCaseInsensitiveContains("AirPods") || manufacturer.localizedCaseInsensitiveContains("Apple"))
    }

    static func all() -> [Microphone] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let lidClosed = clamshellClosed()
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("CADefaultDeviceAggregate"), !uid.hasPrefix("VPAUAggregateAudioDevice"),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = scalar(id, kAudioDevicePropertyTransportType) ?? kAudioDeviceTransportTypeUnknown
            guard scalar(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                  !(lidClosed && transport == kAudioDeviceTransportTypeBuiltIn) else { return nil }
            return Microphone(id: uid, name: name, deviceID: id, transport: transport,
                              manufacturer: string(id, kAudioObjectPropertyManufacturer) ?? "",
                              model: string(id, kAudioDevicePropertyModelUID) ?? "")
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

    private static func clamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    static func scalar(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
