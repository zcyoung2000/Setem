import AppKit
import AVFoundation
import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    let defaults: UserDefaults
    var onResize: (CGFloat) -> Void = { _ in }
    @AppStorage("channel") private var channel = Channel.doubao.rawValue
    @AppStorage("doubaoPunctuation") private var doubaoPunctuation = true
    @AppStorage("hotkey") private var hotkey = Hotkey.rightOption.rawValue
    @AppStorage("tapShortcut") private var tapShortcut = Shortcut.defaultRaw
    @AppStorage("sendHotkey") private var sendHotkey = Hotkey.rightControl.rawValue
    @AppStorage("hudStyle") private var hudStyle = HUDStyle.compact.rawValue
    @AppStorage(DictationOutput.removeTrailingPunctuationKey) private var removeTrailingPunctuation = false
    @AppStorage(MicrophoneMode.key) private var microphoneMode = MicrophoneMode.builtIn.rawValue
    @AppStorage(Recorder.mutePlaybackKey) private var mutePlayback = false
    @ObservedObject private var offline = OfflineAssets.shared
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @StateObject private var compare = ChannelCompare()
    @State private var showCompare = false
    @State private var confirmOfflineDownload = false
    @State private var channelBeforeOffline: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(navigation: SettingsNavigation, defaults: UserDefaults = .standard,
         onResize: @escaping (CGFloat) -> Void = { _ in }) {
        self.navigation = navigation
        self.defaults = defaults
        self.onResize = onResize
    }

    private var contentHeight: CGFloat {
        min(navigation.tab.contentHeight(doubao: channel == Channel.doubao.rawValue),
            max(240, (NSScreen.main?.visibleFrame.height ?? 900) - 140))
    }

    var body: some View {
        TabView(selection: $navigation.tab) {
            channelPane
                .tabItem { Label("识别渠道", systemImage: "waveform") }
                .tag(SettingsTab.channel)
            hotkeyPane
                .tabItem { Label("快捷键", systemImage: "command") }
                .tag(SettingsTab.hotkey)
            audioPane
                .tabItem { Label("声音与界面", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.audio)
            permissionPane
                .tabItem { Label("权限", systemImage: "lock.shield") }
                .tag(SettingsTab.permission)
        }
        .focusEffectDisabled()
        .frame(width: 700, height: contentHeight)
        .onAppear { onResize(contentHeight) }
        .onChange(of: contentHeight) { _, height in onResize(height) }
        .onChange(of: hotkey) { _, _ in avoidSendHotkeyConflict() }
        .onChange(of: tapShortcut) { _, _ in avoidSendHotkeyConflict() }
        .onChange(of: channel) { old, new in
            guard new == Channel.offline.rawValue, !OfflineAssets.installed else { return }
            channelBeforeOffline = old
            confirmOfflineDownload = true
        }
        .onReceive(timer) { _ in
            axTrusted = AXIsProcessTrusted()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .onDisappear { compare.cancel() }
        .sheet(isPresented: $showCompare) {
            ChannelCompareSheet(channel: $channel, compare: compare)
        }
        .confirmationDialog("下载本地模型？", isPresented: $confirmOfflineDownload, titleVisibility: .visible) {
            Button("下载") {
                channelBeforeOffline = nil
                offline.download()
            }
            Button("暂不下载", role: .cancel) {
                if let previous = channelBeforeOffline {
                    channel = previous == Channel.offline.rawValue ? Channel.doubao.rawValue : previous
                }
                channelBeforeOffline = nil
            }
        } message: {
            Text("将下载约 190 MB 的本地引擎库和模型到“应用程序支持/OpenVoice/offline”，下载完成后可随时删除。")
        }
    }

    private var channelPane: some View {
        Form {
            Section {
                Picker("识别渠道", selection: $channel) {
                    ForEach(Channel.available) { item in
                        Text(item.title).tag(item.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if channel == Channel.offline.rawValue {
                    OfflineStatus(offline: offline, onDownload: { confirmOfflineDownload = true }) {
                        offline.delete()
                        if channel == Channel.offline.rawValue { channel = Channel.doubao.rawValue }
                    }
                }
            } header: {
                HStack {
                    Text("识别渠道")
                    Spacer()
                    Button("渠道对比") { showCompare = true }
                        .controlSize(.small)
                        .help("录音一次，对比各渠道的识别结果")
                }
            }
            if channel == Channel.doubao.rawValue {
                Section {
                    Toggle("自动添加标点", isOn: $doubaoPunctuation)
                        .toggleStyle(.switch)
                } header: {
                    Text("豆包输入法")
                } footer: {
                    Text("关闭后，豆包转写不自动添加标点，包括句末标点。下次转写生效。")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeyPane: some View {
        Form {
            Section {
                hotkeyPicker("长按快捷键", selection: $hotkey)
                LabeledContent("点按快捷键") { ShortcutField(raw: $tapShortcut) }
                hotkeyPicker("长按并发送", selection: $sendHotkey)
                if hasHotkeyConflict(Hotkey(rawValue: sendHotkey) ?? .rightControl) {
                    Text("长按并发送快捷键与其他快捷键冲突，请重新绑定。")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text("长按说话，松开结束；点按开始，再按同一快捷键或点击浮窗结束收音，定稿后输入。长按并发送会在完整定稿上屏后自动回车。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private func hotkeyPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Hotkey.allCases) { item in
                HotkeyMenuItem(hotkey: item).tag(item.rawValue)
            }
        }
    }

    private var audioPane: some View {
        Form {
            Section {
                LabeledContent("浮窗大小") {
                    Picker("浮窗大小", selection: $hudStyle) {
                        ForEach(HUDStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 140, alignment: .trailing)
                }
                Toggle("去除末尾标点", isOn: $removeTrailingPunctuation)
                    .toggleStyle(.switch)
                Toggle("录音时静音电脑声音", isOn: $mutePlayback)
                    .toggleStyle(.switch)
                LabeledContent("麦克风模式") {
                    Picker("麦克风模式", selection: $microphoneMode) {
                        ForEach(MicrophoneMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    .frame(width: 280, alignment: .trailing)
                }
            } header: {
                Text("声音与界面")
            } footer: {
                Text("紧凑使用较小的浮窗与字号，标准提供更宽的预览。识别结果定稿后一次性输入。\n开启去除末尾标点后，仅移除最终输入文本末尾的一个标点，保留句中标点。\n开启静音后，两种模式都会静音电脑播放（含耳机），停止收音即恢复原状态。\n优先 AirPods 使用实验性耳机连接辅助；不可用时回退内置麦，本轮保持到结束。内置麦需要开盖。模式更改下次录音生效。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var permissionPane: some View {
        Form {
            Section("权限") {
                LabeledContent {
                    if axTrusted {
                        authorizedStatus
                    } else {
                        Button("去授权") { openPrivacy("Privacy_Accessibility") }
                    }
                } label: {
                    Text("辅助功能")
                    Text("监听快捷键与文字上屏。")
                }
                LabeledContent {
                    switch micStatus {
                    case .authorized: authorizedStatus
                    case .notDetermined:
                        Button("请求授权") { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                    default:
                        Button("去授权") { openPrivacy("Privacy_Microphone") }
                    }
                } label: {
                    Text("麦克风")
                    Text("录制语音流。")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var authorizedStatus: some View {
        Label("已授权", systemImage: "checkmark").foregroundStyle(.green)
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

private struct OfflineStatus: View {
    @ObservedObject var offline: OfflineAssets
    let onDownload: () -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        LabeledContent("本地模型") {
            switch offline.state {
            case .ready:
                HStack {
                    Text("已就绪").foregroundStyle(.green)
                    Button("删除", role: .destructive) { confirmDelete = true }
                }
            case .downloading(let progress):
                HStack {
                    ProgressView(value: progress).frame(width: 120)
                    Text("\(Int(progress * 100))%").monospacedDigit()
                }
            case .missing:
                Button("下载", action: onDownload)
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(.red).lineLimit(1).help(message)
                    Button("重试", action: onDownload)
                    Button("删除", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .confirmationDialog("删除本地模型？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除约 190 MB 的本地引擎库和模型；之后使用本地模型时需要重新下载。")
        }
    }
}

struct ChannelCompareSheet: View {
    @Binding var channel: String
    @ObservedObject var compare: ChannelCompare
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("渠道对比").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            GroupBox {
                VStack(spacing: 10) {
                    Button { compare.toggle() } label: {
                        Label(recordingPrompt, systemImage: compare.phase == .idle ? "mic" : "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    if compare.rows.isEmpty {
                        Text("录音一次，同时比较各渠道的识别结果与耗时。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(8)
            }
            if let error = compare.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(compare.rows) { row in
                        GroupBox(row.channel.title) {
                            VStack(alignment: .leading, spacing: 8) {
                                if !row.text.isEmpty {
                                    Text(row.text).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                HStack {
                                    Text(row.status).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if compare.phase == .idle {
                                        Button("设为默认") {
                                            channel = row.channel.rawValue
                                            dismiss()
                                        }
                                    }
                                }
                            }
                            .padding(4)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 480)
        .focusEffectDisabled()
        .onDisappear { compare.cancel() }
    }

    private var recordingPrompt: String {
        switch compare.phase {
        case .idle: compare.rows.isEmpty ? "开始录音" : "再次录音对比"
        case .recording: "说完了"
        case .recognizing: "取消识别"
        }
    }
}
