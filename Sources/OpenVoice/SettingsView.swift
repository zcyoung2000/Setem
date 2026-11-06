import AppKit
import AVFoundation
import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var meeting: MeetingSession
    @ObservedObject var navigation: SettingsNavigation
    let defaults: UserDefaults
    var onResize: (CGFloat) -> Void = { _ in }
    @AppStorage("channel") private var channel = Channel.doubao.rawValue
    @AppStorage("doubaoPunctuation") private var doubaoPunctuation = true
    @AppStorage("hotkey") private var hotkey = Hotkey.rightOption.rawValue
    @AppStorage("tapShortcut") private var tapShortcut = Shortcut.defaultRaw
    @AppStorage("meetingShortcut") private var meetingShortcut = Shortcut.meetingDefaultRaw
    @AppStorage("sendHotkey") private var sendHotkey = Hotkey.rightControl.rawValue
    @AppStorage("silence") private var silence = 1.5
    @AppStorage("silenceStop") private var silenceStop = true
    @AppStorage("hudStyle") private var hudStyle = HUDStyle.compact.rawValue
    @AppStorage(DictationOutput.removeTrailingPunctuationKey) private var removeTrailingPunctuation = false
    @AppStorage("micUID") private var micUID = ""
    @State private var microphones = Microphone.all()
    @ObservedObject private var offline = OfflineAssets.shared
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @StateObject private var compare = ChannelCompare()
    @State private var showCompare = false
    @State private var confirmOfflineDownload = false
    @State private var channelBeforeOffline: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(meeting: MeetingSession, navigation: SettingsNavigation, defaults: UserDefaults = .standard,
         onResize: @escaping (CGFloat) -> Void = { _ in }) {
        self.meeting = meeting
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
            meetingPane
                .tabItem { Label("会议转写", systemImage: "person.2") }
                .tag(SettingsTab.meeting)
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
            let now = Microphone.all()
            if now != microphones { microphones = now }
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
                        .disabled(meeting.isCapturing)
                        .help(meeting.isCapturing ? "请先暂停会议录音，再测试识别渠道" : "录音一次，对比各渠道的识别结果")
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
                Toggle("停顿自动结束", isOn: $silenceStop)
                    .toggleStyle(.switch)
                    .disabled(tapShortcut == "off")
                Picker("静音时长", selection: $silence) {
                    ForEach([1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) {
                        Text("\($0, specifier: "%g") 秒").tag($0)
                    }
                }
                .disabled(!silenceStop || tapShortcut == "off")
                hotkeyPicker("长按并发送", selection: $sendHotkey)
                if hasHotkeyConflict(Hotkey(rawValue: sendHotkey) ?? .rightControl) {
                    Text("长按并发送快捷键与其他快捷键冲突，请重新绑定。")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text("长按说话，松开结束；点按可开始或结束聆听。长按并发送会在完整定稿上屏后自动回车。")
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

    private var meetingPane: some View {
        Form {
            Section {
                LabeledContent("会议快捷键") {
                    ShortcutField(kind: "会议", allowsModifier: false, raw: $meetingShortcut)
                }
                if let meeting = Shortcut(raw: meetingShortcut), let tap = Shortcut(raw: tapShortcut),
                   meeting.keyCode == tap.keyCode, meeting.modifiers == tap.modifiers {
                    Text("会议快捷键与点按快捷键冲突，请重新绑定。")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("会议转写")
            } footer: {
                Text("按下开始持续录制转写，再按展开或收起悬浮窗。同时收录麦克风和电脑声音；可拖动悬浮窗、暂停或恢复，音频和文字保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
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
                Picker("麦克风", selection: $micUID) {
                    Text("系统默认").tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                    if !micUID.isEmpty, !microphones.contains(where: { $0.id == micUID }) {
                        Text("已断开（暂用系统默认）").tag(micUID)
                    }
                }
            } header: {
                Text("声音与界面")
            } footer: {
                Text("紧凑使用较小的浮窗与字号，标准提供更宽的预览。识别结果定稿后一次性输入。\n开启去除末尾标点后，仅移除最终输入文本末尾的一个标点，保留句中标点。")
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
