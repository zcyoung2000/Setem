import AppKit
import AVFoundation
import Combine
import SwiftUI

enum Channel: String, CaseIterable, Identifiable {
    case doubao, wetype, qwen, offline, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubao: "豆包输入法"
        case .wetype: "微信输入法"
        case .qwen: "千问输入法"
        case .offline: "离线（本地模型）"
        case .all: "多渠道（说完挑选）"
        }
    }
    /// 离线渠道仅 Apple 芯片可用
    static var engines: [Channel] {
        OfflineAssets.supported ? [.doubao, .wetype, .qwen, .offline] : [.doubao, .wetype, .qwen]
    }
    static var available: [Channel] { engines + [.all] }
    static var selectedMulti: [Channel] { selectedMulti(in: .standard) }
    static func selectedMulti(in defaults: UserDefaults) -> [Channel] { normalizedMulti(defaults.stringArray(forKey: "multi")) }
    static func normalizedMulti(_ requested: [String]?, engines: [Channel] = Channel.engines) -> [Channel] {
        let requested = Set(requested ?? engines.map(\.rawValue))
        let selected = engines.filter { requested.contains($0.rawValue) }
        return selected.count >= 2 ? selected : engines
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
    /// 点按模式下静音多久自动结束
    static var silence: Double { UserDefaults.standard.object(forKey: "silence") as? Double ?? 1.5 }
    static var silenceStop: Bool { UserDefaults.standard.object(forKey: "silenceStop") as? Bool ?? true }

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

private struct HotkeyMenuItem: View {
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
    static let meetingDefaultRaw = Shortcut(keyCode: 46, modifiers: CGEventFlags([.maskCommand, .maskShift]).rawValue, name: "M").raw
    static var meeting: Shortcut? {
        Shortcut(raw: UserDefaults.standard.string(forKey: "meetingShortcut") ?? meetingDefaultRaw)
    }

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
            if !recording, raw != "off" {
                Button { raw = "off" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
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
        guard let cg = e.cgEvent else { return }
        let code = Int64(e.keyCode)
        let mods = cg.flags.intersection(Shortcut.mask).rawValue
        if e.type == .keyDown {
            if code == 53, mods == 0 { return stop() }
            guard mods != 0 || Shortcut.functionKeys.contains(code) else { return NSSound.beep() }
            raw = Shortcut(keyCode: code, modifiers: mods, name: Shortcut.keyName(code, e.charactersIgnoringModifiers)).raw
            return stop()
        }
        guard let flag = Shortcut.modifierFlag[code] else { return }
        guard allowsModifier else { return }
        if cg.flags.contains(flag) {
            // 同时按了多个修饰键则不作为单键录入，等待后续组合键
            pendingModifier = pendingModifier == nil ? code : -1
        } else {
            if pendingModifier == code {
                raw = Shortcut(keyCode: code, modifiers: 0, name: Shortcut.modifierName[code]!).raw
                return stop()
            }
            if cg.flags.intersection(Shortcut.mask.union(.maskSecondaryFn)).isEmpty { pendingModifier = nil }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var meeting: MeetingSession
    @AppStorage("channel") private var channel = Channel.doubao.rawValue
    @AppStorage("hotkey") private var hotkey = Hotkey.rightOption.rawValue
    @AppStorage("tapShortcut") private var tapShortcut = Shortcut.defaultRaw
    @AppStorage("meetingShortcut") private var meetingShortcut = Shortcut.meetingDefaultRaw
    @AppStorage("sendHotkey") private var sendHotkey = Hotkey.rightControl.rawValue
    @AppStorage("silence") private var silence = 1.5
    @AppStorage("silenceStop") private var silenceStop = true
    @AppStorage("hudStyle") private var hudStyle = HUDStyle.compact.rawValue
    @AppStorage("streaming") private var streaming = true
    @AppStorage("micUID") private var micUID = ""
    @State private var multi = Channel.selectedMulti
    @State private var microphones = Microphone.all()
    @ObservedObject private var offline = OfflineAssets.shared
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @StateObject private var compare = ChannelCompare()
    @State private var showCompare = false
    @State private var confirmOfflineDownload = false
    @State private var channelBeforeOffline = Channel.doubao.rawValue

    private var shortcutFooter: String {
        var text = streaming
            ? "在任意输入框中长按快捷键说话，识别结果实时打到光标处，松开后按定稿修正。"
            : "在任意输入框中长按快捷键说话，松开后识别结果粘贴到光标处。"
        text += "\n长按 \(Hotkey(rawValue: sendHotkey)?.title ?? Hotkey.rightControl.title) 说话，定稿上屏后自动回车发送；渠道为「全部」时自动采用第一个非空定稿。"
        if tapShortcut != "off" {
            text += silenceStop
                ? "\n或点按一下点按快捷键开始聆听，停顿 \(String(format: "%g", silence)) 秒自动结束，再点一下可提前结束。"
                : "\n或点按一下点按快捷键开始聆听，再点一下结束。"
        }
        if meetingShortcut != "off" {
            text += "\n会议快捷键开始持续收录麦克风和电脑声音，再按展开或收起。可拖动悬浮窗、暂停或恢复；渠道失败自动回退，音频和文字保存在本机。"
        }
        if channel == Channel.all.rawValue {
            text += "\n各渠道实时显示候选，数字键或 ↑↓ 回车选取；未定稿时确认会等待完整结果，再按录音快捷键可继续说。"
        }
        return text
    }

    var body: some View {
        Form {
            Section("识别渠道") {
                HStack {
                    Text("当前渠道")
                    Spacer()
                    Button("对比") { showCompare = true }
                        .disabled(meeting.isCapturing)
                        .help(meeting.isCapturing ? "请先暂停会议录音，再测试识别渠道" : "对比识别渠道")
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                }
                Picker("", selection: $channel) {
                    ForEach(Channel.available) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: channel) { old, new in
                    guard new == Channel.offline.rawValue, !OfflineAssets.installed else { return }
                    channelBeforeOffline = old
                    confirmOfflineDownload = true
                }
                if channel == Channel.all.rawValue {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("同时识别的渠道（至少两个）").font(.caption).foregroundStyle(.secondary)
                        ForEach(Channel.engines) { item in
                            Toggle(item.title, isOn: Binding(get: { multi.contains(item) }, set: { enabled in
                                var selection = Set(multi)
                                if enabled { selection.insert(item) } else { selection.remove(item) }
                                guard selection.count >= 2 else { return }
                                multi = Channel.engines.filter { selection.contains($0) }
                                UserDefaults.standard.set(multi.map(\.rawValue), forKey: "multi")
                            }))
                            .toggleStyle(.checkbox)
                            .disabled(multi.count <= 2 && multi.contains(item))
                        }
                    }
                }
                if channel == Channel.offline.rawValue {
                    OfflineStatus(offline: offline) {
                        offline.delete()
                        if channel == Channel.offline.rawValue { channel = Channel.doubao.rawValue }
                    }
                }
            }

            Section {
                Picker("长按快捷键", selection: $hotkey) {
                    ForEach(Hotkey.allCases) { hotkey in
                        HotkeyMenuItem(hotkey: hotkey)
                            .tag(hotkey.rawValue)
                    }
                }
                LabeledContent("点按快捷键") { ShortcutField(raw: $tapShortcut) }
                Picker("长按并发送", selection: $sendHotkey) {
                    ForEach(Hotkey.allCases) { hotkey in
                        HotkeyMenuItem(hotkey: hotkey)
                            .tag(hotkey.rawValue)
                    }
                }
                .onChange(of: hotkey) { _, _ in avoidSendHotkeyConflict() }
                .onChange(of: tapShortcut) { _, _ in avoidSendHotkeyConflict() }
                LabeledContent("会议快捷键") {
                    ShortcutField(kind: "会议", allowsModifier: false, raw: $meetingShortcut)
                }
                .help("开始会议转写，再按展开或收起；暂停后可在悬浮窗中恢复。")
                if let meeting = Shortcut(raw: meetingShortcut), let tap = Shortcut(raw: tapShortcut),
                   meeting.keyCode == tap.keyCode, meeting.modifiers == tap.modifiers {
                    Text("会议快捷键与点按快捷键冲突，请重新绑定。")
                        .font(.caption).foregroundStyle(.red)
                }
                if hasHotkeyConflict(Hotkey(rawValue: sendHotkey) ?? .rightControl) {
                    Text("长按并发送快捷键与其他快捷键冲突，请重新绑定。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if tapShortcut != "off" {
                    Toggle("静音自动结束", isOn: $silenceStop)
                    Picker("静音时长", selection: $silence) {
                        ForEach([1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { Text("\($0, specifier: "%g") 秒").tag($0) }
                    }.disabled(!silenceStop)
                }
                Picker("提示框样式", selection: $hudStyle) {
                    ForEach(HUDStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                Toggle("边说边上屏", isOn: $streaming)
                    .disabled(channel == Channel.all.rawValue)
                Picker("麦克风", selection: $micUID) {
                    Text("系统默认").tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                    if !micUID.isEmpty, !microphones.contains(where: { $0.id == micUID }) {
                        Text("已断开（暂用系统默认）").tag(micUID)
                    }
                }
            } header: {
                Text("快捷键与输入")
            } footer: {
                Text(shortcutFooter)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("权限") {
                LabeledContent("辅助功能（监听快捷键、粘贴）") {
                    if axTrusted {
                        Text("已授权").foregroundStyle(.green)
                    } else {
                        Button("去授权") { openPrivacy("Privacy_Accessibility") }
                    }
                }
                LabeledContent("麦克风") {
                    switch micStatus {
                    case .authorized: Text("已授权").foregroundStyle(.green)
                    case .notDetermined: Button("请求授权") { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                    default: Button("去授权") { openPrivacy("Privacy_Microphone") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: min(900, (NSScreen.main?.visibleFrame.height ?? 1000) - 100))
        .onReceive(timer) { _ in
            axTrusted = AXIsProcessTrusted()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let now = Microphone.all()
            if now != microphones { microphones = now }
        }
        .onDisappear { compare.cancel() }
        .sheet(isPresented: $showCompare) {
            ChannelCompareSheet(channel: $channel, compare: compare)
        }
        .confirmationDialog(
            "下载离线模型？",
            isPresented: $confirmOfflineDownload,
            titleVisibility: .visible
        ) {
            Button("下载（约 185MB）") { offline.download() }
            Button("暂不下载", role: .cancel) {
                channel = channelBeforeOffline == Channel.offline.rawValue
                    ? Channel.doubao.rawValue
                    : channelBeforeOffline
            }
        } message: {
            Text("将下载离线引擎库和模型到“应用程序支持/OpenVoice/offline”，下载完成后可随时删除。")
        }
    }

    private func hasHotkeyConflict(_ sendHold: Hotkey) -> Bool {
        if let primary = Hotkey(rawValue: hotkey), sendHold.keyCode == primary.keyCode { return true }
        if let tap = Shortcut(raw: tapShortcut), tap.isModifier, sendHold.keyCode == tap.keyCode { return true }
        return false
    }

    private func avoidSendHotkeyConflict() {
        let current = Hotkey(rawValue: sendHotkey) ?? .rightControl
        guard hasHotkeyConflict(current),
              let replacement = Hotkey.allCases.first(where: { !hasHotkeyConflict($0) }) else { return }
        sendHotkey = replacement.rawValue
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

/// 离线模型下载状态
struct OfflineStatus: View {
    @ObservedObject var offline: OfflineAssets
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        LabeledContent("离线模型（约 190MB）") {
            switch offline.state {
            case .ready:
                HStack {
                    Text("已就绪").foregroundStyle(.green)
                    Button("删除") { confirmDelete = true }
                        .buttonStyle(.link)
                        .focusEffectDisabled()
                }
            case .downloading(let p):
                HStack { ProgressView(value: p).frame(width: 120); Text("\(Int(p * 100))%").monospacedDigit() }
            case .missing:
                Button("下载") { offline.download() }
                    .buttonStyle(.link)
                    .focusEffectDisabled()
            case .failed(let msg):
                HStack {
                    Text(msg).foregroundStyle(.red).lineLimit(1)
                    Button("重试") { offline.download() }
                        .buttonStyle(.link)
                        .focusEffectDisabled()
                    Button("删除", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.link)
                        .focusEffectDisabled()
                }
            }
        }
        .confirmationDialog("删除离线模型？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除（约 185MB）", role: .destructive) { onDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本地离线引擎库和模型；之后使用离线识别时需要重新下载。")
        }
    }
}

struct ChannelCompareSheet: View {
    @Binding var channel: String
    @ObservedObject var compare: ChannelCompare
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("渠道对比").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            }
            Button(compare.phase == .recording ? "说完了" : compare.phase == .recognizing ? "取消识别" : "开始说话") {
                compare.toggle()
            }
            .focusEffectDisabled()
            if compare.phase == .recording {
                Text("正在录音，说完再点一次").font(.caption).foregroundStyle(.secondary)
            } else if compare.phase == .recognizing {
                Text("识别中…").font(.caption).foregroundStyle(.secondary)
            }
            if let err = compare.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            ForEach(compare.rows) { row in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.channel.title)
                        if !row.text.isEmpty {
                            Text(row.text).font(.caption).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(row.status).foregroundStyle(.secondary).font(.caption)
                    if compare.phase == .idle {
                        Button("选择") {
                            channel = row.channel.rawValue
                            dismiss()
                        }
                        .focusEffectDisabled()
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .onDisappear { compare.cancel() }
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
