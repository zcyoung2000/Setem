import AppKit
import CoreAudio
import OSLog

struct PlaybackControl: Hashable {
    enum Kind: Hashable { case mute, volume }
    let device: AudioDeviceID
    let uid: String
    let element: AudioObjectPropertyElement
    let kind: Kind
    var silentValue: Float32 { kind == .mute ? 1 : 0 }
}

struct PlaybackOutput {
    let controls: [PlaybackControl]
}

protocol PlaybackHardware: AnyObject {
    func outputs() throws -> [PlaybackOutput]
    func value(_ control: PlaybackControl) throws -> Float32
    func set(_ value: Float32, for control: PlaybackControl) throws
    func observe(_ changed: @escaping () -> Void) -> () -> Void
    func sampleRates() -> [String: Float64]
}

extension PlaybackHardware {
    func sampleRates() -> [String: Float64] { [:] }
}

final class PlaybackMuteLease {
    private let lock = NSLock()
    private var release: ((Bool) -> Void)?
    init(_ release: @escaping (Bool) -> Void) { self.release = release }
    func finish(afterRouteChange: Bool = false) {
        lock.lock()
        let release = self.release
        self.release = nil
        lock.unlock()
        release?(afterRouteChange)
    }
    deinit { finish() }
}

/// Shared across dictation and channel comparison: one capture ending cannot
/// unmute another capture. There is no audio processing or idle polling.
final class PlaybackSilencer {
    static let shared = PlaybackSilencer(hardware: CoreAudioPlaybackHardware())
    private static let log = Logger(subsystem: "do.j3.openvoice", category: "PlaybackMute")
    private let lock = NSRecursiveLock()
    private let hardware: PlaybackHardware
    private var clients: [UUID: (Error) -> Void] = [:]
    private var originals: [PlaybackControl: Float32] = [:]
    private var stopObserving: (() -> Void)?
    private let now: () -> TimeInterval
    private let automaticallyRestore: Bool
    private var playbackRates: [String: Float64] = [:]
    private struct Restoration {
        let id = UUID()
        let deadline: TimeInterval
        var stableSince: TimeInterval?
    }
    private var restoration: Restoration?
    private var restoreWork: DispatchWorkItem?

    init(hardware: PlaybackHardware,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticallyRestore: Bool = true) {
        self.hardware = hardware
        self.now = now
        self.automaticallyRestore = automaticallyRestore
    }

    func acquire(onFailure: @escaping (Error) -> Void = { _ in }) -> PlaybackMuteLease {
        lock.lock()
        // A resumed capture inherits the original playback profile and mute;
        // a late restoration from the preceding capture cannot unmute it.
        if clients.isEmpty, originals.isEmpty { playbackRates = hardware.sampleRates() }
        cancelRestoration()
        let id = UUID()
        clients[id] = onFailure
        if stopObserving == nil {
            stopObserving = hardware.observe { [weak self] in self?.routeChanged() }
        }
        var failure: Error?
        do { try reconcile() } catch { failure = error }
        lock.unlock()
        // Keep the lease and route observation after a transient profile change.
        // The next hardware notification can apply mute when controls reappear.
        if let failure { onFailure(failure) }
        return PlaybackMuteLease { [self] settles in release(id, afterRouteChange: settles) }
    }

    private func release(_ id: UUID, afterRouteChange: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard clients.removeValue(forKey: id) != nil else { return }
        guard clients.isEmpty else { return }
        if afterRouteChange, !originals.isEmpty, !playbackRates.isEmpty {
            // macOS can defer HFP -> playback reconfiguration by about 2 s.
            // Wait for the pre-recording profile plus 250 ms of stability, with
            // a 3 s bound if another application keeps the headset mic open.
            restoration = Restoration(deadline: now() + 3)
            Self.log.notice("restore-wait reason=headset-profile")
            checkRestoration()
        } else if restoration == nil { reset() }
    }

    private func routeChanged() {
        lock.lock()
        guard !clients.isEmpty || !originals.isEmpty || restoration != nil else { lock.unlock(); return }
        if restoration != nil {
            restoration?.stableSince = nil
            checkRestoration()
            lock.unlock()
            return
        }
        do {
            try reconcile()
            stopObservingIfFinished()
            lock.unlock()
        }
        catch {
            let callbacks = Array(clients.values)
            lock.unlock()
            // Per-capture callbacks must not execute under the ownership lock.
            callbacks.forEach { $0(error) }
        }
    }

    private func reconcile() throws {
        let outputs = try hardware.outputs()
        let controls = Set(outputs.flatMap(\.controls))
        // Numeric Core Audio IDs may change after reconnect. Transfer existing
        // ownership by UID and control identity before considering a new snapshot.
        for control in controls where originals[control] == nil {
            if let old = originals.keys.first(where: {
                $0.uid == control.uid && $0.kind == control.kind && $0.element == control.element
            }) { originals[control] = originals.removeValue(forKey: old) }
        }
        let muting = !clients.isEmpty || restoration != nil
        if muting, outputs.contains(where: { $0.controls.isEmpty }) { throw Self.unavailable }
        for control in Array(originals.keys) where !muting || !controls.contains(control) { restore(control) }
        guard muting else { return }
        let before = Set(originals.keys)
        do {
            // The Bluetooth driver may clear mute while replacing its profile.
            // Keep the transition silent without changing any volume sliders.
            if restoration != nil {
                for control in controls where control.kind == .mute && originals[control] != nil {
                    if try hardware.value(control) != control.silentValue {
                        try hardware.set(control.silentValue, for: control)
                    }
                }
            }
            for control in controls where originals[control] == nil {
                let value = try hardware.value(control)
                // Pre-existing silence belongs to the user, not this capture.
                guard value != control.silentValue else { continue }
                originals[control] = value
                try hardware.set(control.silentValue, for: control)
            }
        } catch {
            for control in Array(originals.keys) where !before.contains(control) { restore(control) }
            throw error
        }
    }

    private func restore(_ control: PlaybackControl) {
        guard let original = originals[control], let value = try? hardware.value(control) else { return }
        // Preserve user adjustments and keep responsibility while a device is
        // temporarily disconnected. Reconnect resolves it by UID, never old ID.
        if value == control.silentValue {
            do { try hardware.set(original, for: control) } catch { return }
        }
        originals.removeValue(forKey: control)
    }

    private func reset() {
        for control in Array(originals.keys) { restore(control) }
        if originals.isEmpty { playbackRates.removeAll() }
        stopObservingIfFinished()
    }

    /// The clock is injectable; no hardware, audio or wall-clock delay in tests.
    func checkRestoration() {
        lock.lock(); defer { lock.unlock() }
        guard var pending = restoration, clients.isEmpty else { return }
        let time = now()
        var stable = false
        do {
            try reconcile()
            let current = hardware.sampleRates()
            stable = playbackRates.allSatisfy { current[$0.key] == $0.value }
        } catch { /* A changing profile can temporarily hide its controls. */ }
        if stable {
            if pending.stableSince == nil { pending.stableSince = time }
        } else { pending.stableSince = nil }
        restoration = pending
        let settled = pending.stableSince.map { time - $0 >= 0.25 } ?? false
        if settled || time >= pending.deadline {
            cancelRestoration()
            reset()
            Self.log.notice("restore-ready profileSettled=\(settled)")
            return
        }
        guard automaticallyRestore else { return }
        restoreWork?.cancel()
        let pendingID = pending.id
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.restoration?.id == pendingID else { return }
            self.checkRestoration()
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func cancelRestoration() {
        restoreWork?.cancel()
        restoreWork = nil
        restoration = nil
    }

    private func stopObservingIfFinished() {
        guard clients.isEmpty, originals.isEmpty, restoration == nil else { return }
        stopObserving?()
        stopObserving = nil
    }

    func restoreAll() {
        lock.lock(); defer { lock.unlock() }
        cancelRestoration()
        clients.removeAll()
        reset()
    }

    deinit { restoreAll(); stopObserving?() }

    static var unavailable: ASRError {
        ASRError("无法静音当前输出设备，请切换输出设备或关闭“录音时静音电脑声音”")
    }
}

/// Keep unchanged registrations alive: registering a Core Audio listener can
/// itself enqueue metadata notifications. Replacing every listener in response
/// to those notifications can keep the main queue busy indefinitely.
final class PlaybackRouteObservation<Property: Hashable> {
    private let lock = NSRecursiveLock()
    private let properties: () -> Set<Property>
    private let install: (Property, @escaping () -> Void) -> (() -> Void)?
    private let changed: () -> Void
    private var installed: [Property: () -> Void] = [:]
    private var active = true

    init(properties: @escaping () -> Set<Property>,
         install: @escaping (Property, @escaping () -> Void) -> (() -> Void)?,
         changed: @escaping () -> Void) {
        self.properties = properties
        self.install = install
        self.changed = changed
        refresh()
    }

    private func refresh() {
        let wanted = properties()
        for property in Array(installed.keys) where !wanted.contains(property) {
            installed.removeValue(forKey: property)?()
        }
        for property in wanted where installed[property] == nil {
            installed[property] = install(property) { [weak self] in
                self?.notify()
            }
        }
    }

    private func notify() {
        lock.lock()
        guard active else { lock.unlock(); return }
        refresh()
        lock.unlock()
        // The silencer owns a separate lock; never call it under this lock.
        changed()
    }

    func stop() {
        lock.lock()
        active = false
        let removals = Array(installed.values)
        installed.removeAll()
        lock.unlock()
        removals.forEach { $0() }
    }

    deinit { stop() }
}

/// Uses device controls, never an audio tap, aggregate device, or playback loop.
final class CoreAudioPlaybackHardware: PlaybackHardware {
    private let system = AudioObjectID(kAudioObjectSystemObject)

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: element)
    }

    private func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, into value: inout T) -> Bool {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private func list(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [UInt32] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }

    private func uid(_ device: AudioDeviceID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func devices() -> Set<AudioDeviceID> {
        var devices: Set<AudioDeviceID> = []
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var device = AudioDeviceID(kAudioObjectUnknown)
            if read(system, address(selector, scope: kAudioObjectPropertyScopeGlobal), into: &device), device != kAudioObjectUnknown {
                devices.insert(device)
            }
        }
        // Inspect actual subdevices so every active playback endpoint is muted.
        var leaves: Set<AudioDeviceID> = []
        func expand(_ device: AudioDeviceID, visited: Set<AudioDeviceID>) {
            guard !visited.contains(device) else { return }
            let children = list(device, address(kAudioAggregateDevicePropertyActiveSubDeviceList, scope: kAudioObjectPropertyScopeGlobal))
            if children.isEmpty { leaves.insert(device) }
            else { children.forEach { expand($0, visited: visited.union([device])) } }
        }
        devices.forEach { expand($0, visited: []) }
        return leaves
    }

    func outputs() throws -> [PlaybackOutput] {
        try devices().map { device in
            guard let uid = uid(device) else { throw PlaybackSilencer.unavailable }
            return PlaybackOutput(controls: controls(device, uid: uid))
        }
    }

    func sampleRates() -> [String: Float64] {
        var rates: [String: Float64] = [:]
        for device in devices() {
            var rate: Float64 = 0
            if let uid = uid(device),
               read(device, address(kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal), into: &rate),
               rate > 0 { rates[uid] = rate }
        }
        return rates
    }

    private func controls(_ device: AudioDeviceID, uid: String) -> [PlaybackControl] {
        func control(_ kind: PlaybackControl.Kind, element: UInt32) -> PlaybackControl? {
            let selector = kind == .mute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar
            var property = address(selector, element: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &property),
                  AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue else { return nil }
            return .init(device: device, uid: uid, element: element, kind: kind)
        }
        if let mute = control(.mute, element: kAudioObjectPropertyElementMain) { return [mute] }
        if let volume = control(.volume, element: kAudioObjectPropertyElementMain) { return [volume] }
        var property = address(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw) == noErr else { return [] }
        let count = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
        guard count > 0 else { return [] }
        var channels: [PlaybackControl] = []
        for channel in 1...count {
            guard let item = control(.mute, element: UInt32(channel)) ?? control(.volume, element: UInt32(channel)) else { return [] }
            channels.append(item)
        }
        return channels
    }

    func value(_ control: PlaybackControl) throws -> Float32 {
        guard uid(control.device) == control.uid else { throw PlaybackSilencer.unavailable }
        let selector = control.kind == .mute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar
        let property = address(selector, element: control.element)
        if control.kind == .mute {
            var value: UInt32 = 0
            guard read(control.device, property, into: &value) else { throw PlaybackSilencer.unavailable }
            return Float32(value)
        }
        var value: Float32 = 0
        guard read(control.device, property, into: &value) else { throw PlaybackSilencer.unavailable }
        return value
    }

    func set(_ value: Float32, for control: PlaybackControl) throws {
        guard uid(control.device) == control.uid else { throw PlaybackSilencer.unavailable }
        let selector = control.kind == .mute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar
        var property = address(selector, element: control.element)
        let result: OSStatus
        if control.kind == .mute {
            var value = UInt32(value)
            result = AudioObjectSetPropertyData(control.device, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value)
        } else {
            var value = value
            result = AudioObjectSetPropertyData(control.device, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value)
        }
        guard result == noErr else { throw PlaybackSilencer.unavailable }
    }

    func observe(_ changed: @escaping () -> Void) -> () -> Void {
        struct Property: Hashable {
            let object: AudioObjectID
            let selector: AudioObjectPropertySelector
            let scope: AudioObjectPropertyScope
            let element: AudioObjectPropertyElement
            init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
                self.object = object; selector = address.mSelector
                scope = address.mScope; element = address.mElement
            }
            var address: AudioObjectPropertyAddress {
                .init(mSelector: selector, mScope: scope, mElement: element)
            }
        }
        // Keep system listeners and unchanged device listeners installed. New
        // routes still acquire data-source/stream listeners before reconciling.
        let observation = PlaybackRouteObservation(properties: { [self] in
            var properties: [(AudioObjectID, AudioObjectPropertyAddress)] = [
                (system, address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)),
                (system, address(kAudioHardwarePropertyDefaultSystemOutputDevice, scope: kAudioObjectPropertyScopeGlobal)),
                (system, address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal))
            ]
            for device in devices() {
                properties.append((device, address(kAudioDevicePropertyDataSource)))
                properties.append((device, address(kAudioDevicePropertyStreams)))
                properties.append((device, address(kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)))
            }
            return Set(properties.map { Property($0.0, $0.1) })
        }, install: { property, notify in
            let callback: AudioObjectPropertyListenerBlock = { _, _ in notify() }
            var address = property.address
            guard AudioObjectAddPropertyListenerBlock(property.object, &address, .main, callback) == noErr else { return nil }
            return {
                var address = property.address
                AudioObjectRemovePropertyListenerBlock(property.object, &address, .main, callback)
            }
        }, changed: changed)
        return { observation.stop() }
    }
}
