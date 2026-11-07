import AppKit
import AVFoundation
import Combine
import SwiftUI

enum Channel: String, CaseIterable, Identifiable {
    case doubao, wetype, qwen, offline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubao: "豆包输入法"
        case .wetype: "微信输入法"
        case .qwen: "千问输入法"
        case .offline: "本地模型"
        }
    }
    /// 本地模型仅 Apple 芯片可用
    static var engines: [Channel] {
        OfflineAssets.supported ? [.doubao, .wetype, .qwen, .offline] : [.doubao, .wetype, .qwen]
    }
    static var available: [Channel] { engines }
    static func migrateLegacySelection(in defaults: UserDefaults) {
        if defaults.string(forKey: "channel") == "all" {
            defaults.set(Channel.doubao.rawValue, forKey: "channel")
        }
        for key in ["multi", "lastPick", "pickCounts"] { defaults.removeObject(forKey: key) }
    }
    static var current: Channel { current(in: .standard) }
    static func current(in defaults: UserDefaults) -> Channel {
        let c = Channel(rawValue: defaults.string(forKey: "channel") ?? "") ?? .doubao
        return available.contains(c) ? c : .doubao
    }
}

enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn
    var id: String { rawValue }
    static var current: Hotkey { Hotkey(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .rightOption }
    static var sendHold: Hotkey {
        if let value = UserDefaults.standard.string(forKey: "sendHotkey"),
           let hotkey = Hotkey(rawValue: value) { return hotkey }

        // Migrate the short-lived recorder-based setting used by 0.6.0 local builds.
        if let raw = UserDefaults.standard.string(forKey: "sendHoldShortcut"),
           let shortcut = Shortcut(raw: raw),
           let hotkey = Hotkey.allCases.first(where: { $0.keyCode == shortcut.keyCode }) {
            return hotkey
        }
        return .rightControl
    }
    static func removeRetiredSettings(in defaults: UserDefaults) {
        for key in ["silence", "silenceStop"] where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    var title: String {
        switch self {
        case .rightOption: "右 Option ⌥"
        case .rightCommand: "右 Command ⌘"
        case .rightControl: "右 Control ⌃"
        case .fn: "Fn"
        }
    }

    /// SF Symbols provides the system-rendered globe for the Fn key.
    var symbolName: String? {
        self == .fn ? "globe" : nil
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        case .fn: .maskSecondaryFn
        }
    }
}

enum HUDStyle: String, CaseIterable, Identifiable {
    case compact, standard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "紧凑"
        case .standard: "标准"
        }
    }
    static var current: HUDStyle {
        HUDStyle(rawValue: UserDefaults.standard.string(forKey: "hudStyle") ?? "") ?? .compact
    }
}

struct HotkeyMenuItem: View {
    let hotkey: Hotkey

    var body: some View {
        if let symbolName = hotkey.symbolName {
            // Picker moves standalone images to AppKit's leading icon slot;
            // inline text keeps the globe after the key name.
            Text("\(hotkey.title) ") + Text(Image(systemName: symbolName))
        } else {
            Text(hotkey.title)
        }
    }
}

/// 用户录制的点按快捷键：单个修饰键（区分左右）或 修饰键+按键 组合
struct Shortcut: Equatable {
    var keyCode: Int64
    var modifiers: UInt64
    var name: String

    static let mask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    static let modifierFlag: [Int64: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand, 58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl, 56: .maskShift, 60: .maskShift, 63: .maskSecondaryFn,
    ]
    static let modifierName: [Int64: String] = [
        54: "右 ⌘", 55: "左 ⌘", 58: "左 ⌥", 61: "右 ⌥", 59: "左 ⌃", 62: "右 ⌃", 56: "左 ⇧", 60: "右 ⇧", 63: "Fn",
    ]
    /// 不带修饰键也允许单独使用的键（F1–F20）
    static let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    private static let specialNames: [Int64: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    var isModifier: Bool { Self.modifierFlag[keyCode] != nil }

    var title: String {
        let f = CGEventFlags(rawValue: modifiers)
        var t = ""
        if f.contains(.maskControl) { t += "⌃" }
        if f.contains(.maskAlternate) { t += "⌥" }
        if f.contains(.maskShift) { t += "⇧" }
        if f.contains(.maskCommand) { t += "⌘" }
        return t + name
    }

    var raw: String { "\(keyCode),\(modifiers),\(name)" }

    init(keyCode: Int64, modifiers: UInt64, name: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.name = name
    }

    init?(raw: String) {
        let parts = raw.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = Int64(parts[0]), let mods = UInt64(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: mods, name: String(parts[2]))
    }

    static func keyName(_ code: Int64, _ chars: String?) -> String {
        specialNames[code] ?? modifierName[code] ?? (chars?.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(code)"
    }

    static let defaultRaw = Shortcut(keyCode: 54, modifiers: 0, name: "右 ⌘").raw
    /// "off" 表示关闭；按设置项分别缓存，事件回调里频繁读取
    private static var tapCache: (String, Shortcut?) = ("", nil)
    static var tap: Shortcut? {
        let raw = UserDefaults.standard.string(forKey: "tapShortcut") ?? defaultRaw
        if tapCache.0 != raw { tapCache = (raw, Shortcut(raw: raw)) }
        return tapCache.1
    }

}

/// 录制下一次按键：单独按一个修饰键，或按下 修饰键+键；Esc 取消
struct ShortcutField: View {
    var kind = "点按"
    var allowsModifier = true
    @Binding var raw: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifier: Int64?

    var body: some View {
        HStack {
            Button(recording ? "请按下快捷键…（Esc 取消）" : (Shortcut(raw: raw)?.title ?? "未设置")) {
                recording ? stop() : start()
            }
            .accessibilityLabel("\(kind)快捷键")
            .accessibilityValue(recording ? "正在录制" : (Shortcut(raw: raw)?.title ?? "未设置"))
            if !recording, raw != "off" {
                Button { raw = "off" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("关闭\(kind)快捷键")
                    .help("关闭\(kind)快捷键")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        pendingModifier = nil
        HotkeyMonitor.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotkeyMonitor.paused = false
    }

    private func handle(_ e: NSEvent) {
        let code = Int64(e.keyCode)
        let flags = CGEventFlags(rawValue: UInt64(
            e.modifierFlags.intersection([.control, .option, .shift, .command]).rawValue
        ))
        let mods = flags.intersection(Shortcut.mask).rawValue
        if e.type == .keyDown {
            if code == 53, mods == 0 { return stop() }
            guard mods != 0 || Shortcut.functionKeys.contains(code) else { return NSSound.beep() }
            raw = Shortcut(keyCode: code, modifiers: mods, name: Shortcut.keyName(code, e.charactersIgnoringModifiers)).raw
            return stop()
        }
        guard let flag = Shortcut.modifierFlag[code] else { return }
        guard allowsModifier else { return }
        if flags.contains(flag) {
            // 同时按了多个修饰键则不作为单键录入，等待后续组合键
            pendingModifier = pendingModifier == nil ? code : -1
        } else {
            if pendingModifier == code {
                raw = Shortcut(keyCode: code, modifiers: 0, name: Shortcut.modifierName[code]!).raw
                return stop()
            }
            if flags.intersection(Shortcut.mask.union(.maskSecondaryFn)).isEmpty { pendingModifier = nil }
        }
    }
}

/// 设置里录音一次，各渠道并行识别并实时出字
@MainActor
final class ChannelCompare: ObservableObject {
    enum Phase { case idle, recording, recognizing }
    struct Row: Identifiable {
        var id: String { channel.rawValue }
        let channel: Channel
        var text = ""
        var status = ""
    }

    @Published var phase = Phase.idle
    @Published var rows: [Row] = []
    @Published var error: String?

    private let recorder = Recorder()
    private let pool = DictationEnginePool()
    private var generation = 0
    private var pending: Set<Channel> = []
    private var work: Task<Void, Never>?

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stopRecord()
        case .recognizing: cancel()
        }
    }

    func cancel() {
        generation += 1
        pending = []
        if phase == .recording { recorder.stop() }
        work?.cancel()
        work = nil
        HotkeyMonitor.paused = false
        phase = .idle
    }

    private func start() {
        error = nil
        rows = Channel.engines.map { ch in
            if ch == .offline, !OfflineAssets.installed {
                return Row(channel: ch, status: "跳过（未下载）")
            }
            return Row(channel: ch, status: "识别中")
        }
        let active = rows.filter { $0.status == "识别中" }.map(\.channel)
        generation += 1
        let gen = generation
        pending = Set(active)
        HotkeyMonitor.paused = true
        do {
            let source = try recorder.start()
            phase = .recording
            for channel in active { pool.prewarm(channel) }
            let streams = Self.fanout(source, n: active.count)
            work = Task { await run(active, streams, gen: gen) }
        } catch {
            HotkeyMonitor.paused = false
            phase = .idle
            self.error = error.localizedDescription
        }
    }

    private func stopRecord() {
        guard phase == .recording else { return }
        recorder.stop()
        phase = .recognizing
    }

    private func run(_ channels: [Channel], _ streams: [AsyncStream<[Int16]>], gen: Int) async {
        await withTaskGroup(of: Void.self) { g in
            for (i, ch) in channels.enumerated() {
                let stream = streams[i]
                let lease = pool.take(ch)
                g.addTask { await self.recognize(ch, stream, lease: lease, gen: gen) }
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == gen else { return }
            if self.phase == .recording { self.recorder.stop() }
            HotkeyMonitor.paused = false
            self.phase = .idle
            self.work = nil
        }
    }

    private func recognize(_ ch: Channel, _ stream: AsyncStream<[Int16]>, lease: DictationEnginePool.Lease, gen: Int) async {
        let t0 = Date()
        do {
            await lease.ready()
            try Task.checkCancellation()
            let text = try await lease.engine.run(audio: stream) { [weak self] p in
                DispatchQueue.main.async { [weak self] in self?.set(ch, gen: gen, text: p) }
            }
            if !Task.isCancelled { pool.reuse(lease.engine, channel: ch) }
            let sec = String(format: "%.2fs", Date().timeIntervalSince(t0))
            DispatchQueue.main.async { [weak self] in self?.set(ch, gen: gen, text: text, status: sec) }
        } catch is CancellationError {
            DispatchQueue.main.async { [weak self] in self?.set(ch, gen: gen, status: "已取消") }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.set(ch, gen: gen, status: message) }
        }
    }

    private func set(_ ch: Channel, gen: Int, text: String? = nil, status: String? = nil) {
        guard generation == gen, pending.contains(ch), let i = rows.firstIndex(where: { $0.channel == ch }) else { return }
        if let text { rows[i].text = text }
        if let status { rows[i].status = status; pending.remove(ch) }
    }

    nonisolated static func fanout(_ source: AsyncStream<[Int16]>, n: Int) -> [AsyncStream<[Int16]>] {
        var conts: [AsyncStream<[Int16]>.Continuation] = []
        var streams: [AsyncStream<[Int16]>] = []
        for _ in 0..<n {
            let (s, c) = AsyncStream<[Int16]>.makeStream()
            streams.append(s)
            conts.append(c)
        }
        Task {
            for await frame in source {
                for c in conts { c.yield(frame) }
            }
            for c in conts { c.finish() }
        }
        return streams
    }
}
