import AudioToolbox
import CoreAudio
import IOKit
import Foundation

/// Headset mode keeps the Bluetooth headset input open between recordings, the way
/// a call does, so its profile switch never cuts speech. Otherwise every recording
/// opens the chosen computer microphone. Changes apply to the next recording.
struct MicrophonePreference: Equatable {
    static let headsetKey = "headsetMode"
    static let computerKey = "computerMicrophoneUID"
    var headset: Bool
    /// Empty selects the MacBook built-in microphone.
    var computerUID: String

    static func current(in defaults: UserDefaults) -> Self {
        Self(headset: defaults.bool(forKey: headsetKey), computerUID: defaults.string(forKey: computerKey) ?? "")
    }

    /// The retired two-way mode and the older device picker map onto headset mode
    /// or a wired computer microphone; neither may silently follow the system default.
    static func migrate(in defaults: UserDefaults, microphones: [Microphone]? = nil) {
        let mode = defaults.string(forKey: "microphoneMode")
        let old = defaults.string(forKey: "micUID") ?? ""
        if defaults.object(forKey: headsetKey) == nil, mode != nil || !old.isEmpty {
            let device = old.isEmpty ? nil : (microphones ?? Microphone.all()).first { $0.id == old }
            // An explicit retired mode wins over the older device picker.
            defaults.set(mode.map { $0 == "airPodsPreferred" } ?? (device?.isHeadset == true), forKey: headsetKey)
            if let device, device.isComputerInput, !device.isBuiltIn,
               defaults.object(forKey: computerKey) == nil {
                defaults.set(device.id, forKey: computerKey)
            }
        }
        defaults.removeObject(forKey: "microphoneMode")
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
    /// Bluetooth inputs switch the headset into its call profile when opened.
    var isHeadset: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isAirPods: Bool {
        isHeadset && (name.localizedCaseInsensitiveContains("AirPods") || model.localizedCaseInsensitiveContains("AirPods") || manufacturer.localizedCaseInsensitiveContains("Apple"))
    }
    /// Built-in, USB, Thunderbolt, display and similar physical inputs. Virtual
    /// loopback/meeting devices and aggregates are never offered as a microphone.
    var isComputerInput: Bool {
        !isHeadset && ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                        kAudioDeviceTransportTypeAutoAggregate].contains(transport)
    }

    /// AirPods first, then any other Bluetooth headset, in a stable order.
    static func headset(in microphones: [Microphone]) -> Microphone? {
        microphones.first { $0.isAirPods } ?? microphones.first { $0.isHeadset }
    }

    /// The chosen computer microphone, or built-in when it is unplugged.
    static func computer(_ uid: String, in microphones: [Microphone]) -> Microphone? {
        (uid.isEmpty ? nil : microphones.first { $0.id == uid && $0.isComputerInput })
            ?? microphones.first { $0.isBuiltIn }
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
