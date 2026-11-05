import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let enginePool: DictationEnginePool
    private let providedCapture: DictationCapture?
    private let activity = DictationActivity()
    private lazy var capture = providedCapture ?? DictationCapture(start: { [unowned self] in try self.recorder.start() },
                                                                  stop: { [unowned self] in self.recorder.stop() })
    private let hud: HUD
    private let insertText: (String, Bool) -> Void
    private let makeStreamTyper: () -> StreamTyper
    private let defaults: UserDefaults
    private let pick = PickHUD()
    private let meeting = MeetingSession()
    private var meetingPanel: MeetingPanel?
    private var sleepObserver: Any?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var recording = false
    /// 点按开启的会话：静音超时自动结束
    private var autoStop = false
    private var caretAnchor: NSRect?
    private var previousApp: NSRunningApplication?
    private var streamingNow = false
    private var streamTyper: StreamTyper?
    private var hasSession: Bool { dictation.isActive || picker.isActive }
    init(capture: DictationCapture? = nil, enginePool: DictationEnginePool? = nil, hud: HUD? = nil,
         defaults: UserDefaults = .standard,
         insertText: @escaping (String, Bool) -> Void = { TextInserter.insert($0, sendsReturn: $1) },
         makeStreamTyper: @escaping () -> StreamTyper = { StreamTyper() }) {
        providedCapture = capture
        self.enginePool = enginePool ?? DictationEnginePool()
        self.hud = hud ?? HUD()
        self.defaults = defaults
        self.insertText = insertText
        self.makeStreamTyper = makeStreamTyper
        super.init()
    }

    private(set) lazy var dictation: DictationSession = {
        let model = DictationSession(startCapture: { [unowned self] in try self.capture.take() },
                                     stopCapture: { [unowned self] in self.capture.stop() }, enginePool: enginePool)
        model.onCaptureChanged = { [weak self] in self?.captureChanged($0) }
        model.onSpeech = { [weak self] in self?.activity.speaking() }
        model.onUpdate = { [weak self] text in
            guard let self else { return }
            if let typer = self.streamTyper { typer.update(text) }
            else { self.hud.update(text) }
        }
        model.onFinish = { [weak self] result in self?.finishDictation(result) }
        model.onCancel = { [weak self] text, message in
            guard let self else { return }
            self.streamTyper?.finish()
            self.streamTyper = nil
            if let message {
                if !self.streamingNow, !text.isEmpty { self.insertText(text, false) }
                self.fail(text.isEmpty ? message : "\(message)，已保留已识别的文字")
            } else { self.hud.hide() }
        }
        return model
    }()
    private(set) lazy var picker: DictationPicker = {
        let model = DictationPicker(startCapture: { [unowned self] in try self.capture.take() },
                                    stopCapture: { [unowned self] in self.capture.stop() }, pool: enginePool, defaults: defaults)
        model.onCaptureChanged = { [weak self] in self?.captureChanged($0) }
        model.onSpeech = { [weak self] in self?.activity.speaking() }
        model.onUpdate = { [weak self] rows, selected in self?.showPick(rows, selected: selected) }
        model.onChoice = { [weak self] in self?.finishPick($0) }
        model.onCancel = { [weak self] text, message in self?.cancelPick(text, message: message) }
        model.onInvalidChoice = { NSSound.beep() }
        return model
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        recorder.onLevel = { [weak self] v in
            DispatchQueue.main.async {
                self?.hud.level(v)
                self?.checkSilence(v)
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        meetingPanel = MeetingPanel(model: meeting)
        meeting.onDismiss = { [weak self] in self?.meetingPanel?.hide() }
        meeting.onCaptureChanged = { [weak self] in self?.setIcon(recording: self?.recording ?? false) }
        meeting.canBeginCapture = { [weak self] in self?.hasSession == false && self?.capture.isPrimed == false && !HotkeyMonitor.paused }
        // A sleeping Mac cannot record. Stop explicitly and retain every captured frame.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.meeting.interrupt("电脑即将睡眠，会议已暂停；唤醒后点击恢复转写。")
            }
        }

        requestInitialAccessibilityPermission()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        pick.onChoose = { [weak self] in self?.picker.choose($0) }
        pick.onSelectionChange = { [weak self] in self?.picker.select($0) }
        pick.onDigit = { [weak self] in self?.picker.digit($0) }
        pick.onCancel = { [weak self] in self?.abort(nil) }
        hotkey.onPress = { [weak self] in self?.primeRecording() }
        hotkey.onCancel = { [weak self] in self?.capture.disarm() }
        hotkey.onLongPress = { [weak self] send in self?.begin(sendOnFinish: send) }
        hotkey.onRelease = { [weak self] _ in
            if self?.autoStop == false { self?.end() }
        }
        hotkey.onTap = { [weak self] in
            guard let self else { return }
            guard !self.meeting.isCapturing else { self.meetingPanel?.show(); return }
            if self.recording { self.end() }
            else { self.begin(autoStop: true, sendOnFinish: false) }
        }
        hotkey.onMeeting = { [weak self] in self?.toggleMeeting() }
        hotkey.onEscape = { [weak self] in
            guard let self, self.hasSession || self.capture.isPrimed else { return }
            self.abort(nil)
        }
        hotkey.onPickKey = { [weak self] key in
            guard let self, self.picker.isActive, !self.picker.sendsReturn else { return false }
            switch key {
            case .up: self.picker.move(-1)
            case .down: self.picker.move(1)
            case .enter: self.picker.confirm()
            case .escape: self.abort(nil)
            case let .digit(value): self.picker.digit(value)
            }
            return true
        }
        hotkey.start()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleSettingsShortcut(event) == true ? nil : event
        }
    }

    /// 菜单栏图标可能被刘海/菜单栏管理器藏起来，再次打开 App 即弹出设置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func requestInitialAccessibilityPermission() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didPromptAccessibility") else { return }
        // Existing installations have already been offered permission. An update must
        // not repeat the system prompt when the stored authorization is still denied.
        let configured = ["hotkey", "tapShortcut", "sendHotkey", "channel", "micUID", "meetingShortcut"]
            .contains { defaults.object(forKey: $0) != nil }
        defaults.set(true, forKey: "didPromptAccessibility")
        guard !configured, !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await meeting.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func primeRecording() {
        guard !meeting.isCapturing, !recording, !HotkeyMonitor.paused else { return }
        try? capture.arm()
        let channels: [Channel]
        if dictation.isActive { channels = [dictation.channel] }
        else if picker.isActive { channels = picker.rows.filter { $0.phase != .skipped }.map(\.channel) }
        else if Channel.current(in: defaults) == .all { channels = Channel.selectedMulti(in: defaults).filter { $0 != .offline || OfflineAssets.installed } }
        else { channels = [Channel.current(in: defaults)] }
        for channel in channels { enginePool.prewarm(channel) }
    }

    private func captureChanged(_ recording: Bool) {
        self.recording = recording
        if recording { activity.start() }
        else {
            activity.stop()
            autoStop = false
            if dictation.isActive || (picker.isActive && picker.sendsReturn) {
                hud.showThinking()
            } else { hud.hide() }
        }
        setIcon(recording: recording)
    }

    func begin(autoStop: Bool = false, sendOnFinish: Bool = false) {
        guard !meeting.isCapturing else { capture.disarm(); meetingPanel?.show(); return }
        guard !recording else { return }
        if picker.isActive || (!dictation.isActive && Channel.current(in: defaults) == .all) {
            let continuing = picker.isActive
            if !continuing {
                caretAnchor = Caret.bounds()
                previousApp = NSWorkspace.shared.frontmostApplication
            }
            do {
                let skipped: Set<Channel> = OfflineAssets.installed ? [] : [.offline]
                guard try picker.start(channels: Channel.selectedMulti(in: defaults), skipped: skipped, sendsReturn: sendOnFinish) else { return }
            } catch {
                if !continuing { previousApp = nil }
                fail("麦克风启动失败：\(error.localizedDescription)")
                return
            }
            self.autoStop = autoStop
            if picker.sendsReturn { hud.show("", listening: true) }
            return
        }
        let continuing = dictation.isActive
        let streaming = continuing ? streamingNow : (defaults.object(forKey: "streaming") as? Bool ?? true)
        do {
            guard try dictation.start(channel: Channel.current(in: defaults), sendsReturn: sendOnFinish, streaming: streaming) else { return }
        } catch {
            fail("麦克风启动失败：\(error.localizedDescription)")
            return
        }
        if !continuing {
            streamingNow = streaming
            streamTyper = streamingNow ? makeStreamTyper() : nil
        }
        self.autoStop = autoStop
        hud.show(dictation.text, listening: true)
    }

    private func finishDictation(_ result: DictationSession.Result) {
        let typer = streamTyper
        streamTyper = nil
        if !result.text.isEmpty { typer?.update(result.text) }
        typer?.finish()
        if let error = result.error {
            if typer == nil, !result.text.isEmpty { insertText(result.text, false) }
            let tail = result.text.isEmpty ? "" : "，已保留已识别的文字"
            fail("识别失败：\(error)\(tail)")
        } else if result.text.isEmpty, typer == nil {
            hud.show("没有识别到内容", listening: false)
            hud.hide(after: 1)
        } else {
            hud.hide()
            if typer == nil { insertText(result.text, result.sendsReturn) }
            else if result.sendsReturn { TextInserter.pressReturn(after: 0.08) }
        }
    }

    private func showPick(_ rows: [DictationPicker.Row], selected: Int) {
        guard !picker.sendsReturn else { pick.hide(); return }
        hud.hide()
        pick.show(rows.map { PickItem(channel: $0.channel, text: $0.text, status: $0.status) },
                  anchor: caretAnchor, selected: selected)
    }

    private func finishPick(_ choice: DictationPicker.Choice) {
        pick.hide()
        hud.hide()
        let app = previousApp
        previousApp = nil
        app?.activate()
        let insert = insertText
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            insert(choice.text, choice.sendsReturn)
        }
    }

    private func cancelPick(_ text: String, message: String?) {
        pick.hide()
        let app = previousApp
        previousApp = nil
        app?.activate()
        if let message {
            if !text.isEmpty {
                let insert = insertText
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { insert(text, false) }
            }
            fail(text.isEmpty ? message : "\(message)，已保留已识别的文字")
        } else { hud.hide() }
    }

    private func checkSilence(_ level: Float) {
        guard recording, autoStop else { return }
        if activity.shouldStop(level: level, silence: Hotkey.silence, enabled: Hotkey.silenceStop) { end() }
    }

    func end() {
        guard recording else { capture.disarm(); return }
        if dictation.isActive {
            dictation.end()
        } else if picker.isActive {
            picker.end()
        }
    }

    private func abort(_ message: String?) {
        capture.disarm()
        if dictation.isActive { dictation.cancel(message) }
        else if picker.isActive { picker.cancel(message) }
        else { hud.hide() }
    }

    private func fail(_ message: String) {
        hud.show(message, listening: false)
        hud.hide(after: 2.5)
    }

    private func setIcon(recording: Bool) {
        statusItem?.button?.image = NSImage(systemSymbolName: meeting.isCapturing ? "waveform.circle.fill" : recording ? "mic.fill" : "mic", accessibilityDescription: "OpenVoice")
    }

    /// Bundle ID and the app-support directory changed with the OpenVoice rename.
    private func migrateLegacyState() {
        _ = appSupportDirectory()

        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/do.j3.voicekey.plist")
        guard let values = NSDictionary(contentsOf: preferences) as? [String: Any] else { return }

        let defaults = UserDefaults.standard
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "长按 \(Hotkey.current.title) 说话", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let sendHeader = NSMenuItem(title: "长按 \(Hotkey.sendHold.title) 说话并发送", action: nil, keyEquivalent: "")
        sendHeader.isEnabled = false
        menu.addItem(sendHeader)
        menu.addItem(.separator())
        let meetingItem = NSMenuItem(title: meeting.hasOpenMeeting ? "显示会议转写" : "开始会议转写", action: #selector(showMeeting), keyEquivalent: "")
        meetingItem.target = self
        menu.addItem(meetingItem)
        if meeting.hasOpenMeeting {
            let pauseTitle = meeting.phase == .paused ? (meeting.record.captureEnded == true ? "继续会议转写" : "恢复会议转写") : "暂停会议转写"
            let pause = NSMenuItem(title: pauseTitle, action: #selector(toggleMeetingPause), keyEquivalent: "")
            pause.target = self
            pause.isEnabled = meeting.phase == .recording || meeting.phase == .paused
            menu.addItem(pause)
        } else if MeetingSession.latestDirectory != nil {
            let restore = NSMenuItem(title: "恢复上次会议 / 补转", action: #selector(restoreMeeting), keyEquivalent: "")
            restore.target = self
            menu.addItem(restore)
        }
        let records = NSMenuItem(title: "打开会议记录", action: #selector(openMeetingRecords), keyEquivalent: "")
        records.target = self
        menu.addItem(records)
        menu.addItem(.separator())
        for c in Channel.available {
            let item = NSMenuItem(title: c.title, action: #selector(selectChannel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.state = c == Channel.current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            let ax = NSMenuItem(title: "⚠️ 需要辅助功能权限…", action: #selector(openSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        let settings = NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectChannel(_ sender: NSMenuItem) {
        let previous = Channel.current.rawValue
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "channel")
        guard sender.representedObject as? String == Channel.offline.rawValue, !OfflineAssets.installed else { return }

        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = "下载离线模型？"
            alert.informativeText = "将下载约 185MB 的离线引擎库和模型，之后可随时在设置中删除。"
            alert.addButton(withTitle: "下载")
            alert.addButton(withTitle: "取消")

            if alert.runModal() == .alertFirstButtonReturn {
                OfflineAssets.shared.download()
            } else {
                UserDefaults.standard.set(previous, forKey: "channel")
            }
        }
    }

    private func toggleMeeting() {
        if meeting.hasOpenMeeting {
            meetingPanel?.toggle()
            meetingPanel?.show()
        } else { showMeeting() }
    }

    @objc private func showMeeting() {
        guard !HotkeyMonitor.paused else {
            fail("请先结束渠道对比或快捷键设置，再开始会议转写")
            return
        }
        guard !hasSession, !capture.isPrimed else {
            fail("请先结束当前语音输入，再开始会议转写")
            return
        }
        if !meeting.hasOpenMeeting { meeting.start() }
        meetingPanel?.show()
    }

    @objc private func toggleMeetingPause() {
        meeting.phase == .paused ? meeting.resume() : meeting.pause()
        meetingPanel?.show()
    }

    @objc private func restoreMeeting() {
        guard !hasSession, !capture.isPrimed, !meeting.hasOpenMeeting else { return }
        meeting.restoreLatest()
        meetingPanel?.show()
    }

    @objc private func openMeetingRecords() {
        do {
            try FileManager.default.createDirectory(at: MeetingArchive.root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(MeetingArchive.root)
        } catch { fail(error.localizedDescription) }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(meeting: meeting)))
            window.title = "OpenVoice 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // Accessory apps need an explicit activation request before their key window
        // is allowed to rise above the current foreground application.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    /// 菜单栏 App 没有「文件 → 关闭」，⌘W 不会自动关窗口
    private func handleSettingsShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return false }
        guard event.keyCode == 13 else { return false } // W
        guard let win = settingsWindow, win.isVisible, win.isKeyWindow else { return false }
        win.performClose(nil)
        return true
    }
}
