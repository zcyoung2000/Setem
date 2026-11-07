import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey: HotkeyMonitor
    private let recorder: Recorder
    private let enginePool: DictationEnginePool
    private let providedCapture: DictationCapture?
    private lazy var capture = providedCapture ?? DictationCapture(start: { [unowned self] in try self.recorder.start() },
                                                                  stop: { [unowned self] in self.recorder.stop() })
    private let hud: HUD
    private let insertText: (String, Bool) -> Void
    private let defaults: UserDefaults
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var recording = false
    /// 点按开启的持续录音，由快捷键或浮窗手动结束。
    private var tapRecording = false
    private var hasSession: Bool { dictation.isActive }
    init(capture: DictationCapture? = nil, enginePool: DictationEnginePool? = nil, hud: HUD? = nil,
         defaults: UserDefaults = .standard, hotkey: HotkeyMonitor = HotkeyMonitor(),
         insertText: @escaping (String, Bool) -> Void = { TextInserter.insert($0, sendsReturn: $1) }) {
        providedCapture = capture
        recorder = Recorder(defaults: defaults)
        self.hotkey = hotkey
        self.enginePool = enginePool ?? DictationEnginePool()
        self.hud = hud ?? HUD()
        self.defaults = defaults
        self.insertText = { text, sendsReturn in
            let output = DictationOutput.textForInsertion(text, defaults: defaults)
            guard !output.isEmpty else { return }
            insertText(output, sendsReturn)
        }
        super.init()
        Channel.migrateLegacySelection(in: defaults)
        Hotkey.removeRetiredSettings(in: defaults)
        self.hud.onStopRecording = { [weak self] in
            guard let self, self.recording, self.tapRecording else { return }
            self.end()
        }
        configureHotkeys()
    }

    private(set) lazy var dictation: DictationSession = {
        let model = DictationSession(startCapture: { [unowned self] in try self.capture.take() },
                                     stopCapture: { [unowned self] in self.capture.stop() },
                                     captureFailure: { [unowned self] in self.recorder.failureSnapshot }, enginePool: enginePool)
        model.onCaptureChanged = { [weak self] in self?.captureChanged($0) }
        model.onUpdate = { [weak self] text in
            guard let self else { return }
            self.hud.update(text)
        }
        model.onFinish = { [weak self] result in self?.finishDictation(result) }
        model.onCancel = { [weak self] text, message in
            guard let self else { return }
            if let message {
                if !text.isEmpty { self.insertText(text, false) }
                self.fail(text.isEmpty ? message : "\(message)，已保留已识别的文字")
            } else { self.hud.hide() }
        }
        return model
    }()
    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyState()
        Hotkey.removeRetiredSettings(in: defaults)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        recorder.onLevel = { [weak self] v in
            DispatchQueue.main.async {
                self?.hud.level(v)
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        requestInitialAccessibilityPermission()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        hotkey.start()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleSettingsShortcut(event) == true ? nil : event
        }
    }

    private func configureHotkeys() {
        hotkey.onPress = { [weak self] in self?.primeRecording() }
        hotkey.onTapPress = { [weak self] in
            guard let self, !self.hasSession else { return }
            self.primeRecording()
        }
        hotkey.onCancel = { [weak self] in self?.capture.disarm() }
        hotkey.onLongPress = { [weak self] send in self?.begin(sendOnFinish: send) }
        hotkey.onRelease = { [weak self] _ in
            if self?.tapRecording == false { self?.end() }
        }
        hotkey.onTap = { [weak self] in
            guard let self else { return }
            // An existing session either stops capturing or keeps waiting for its
            // final. A tap never cancels it or starts another segment while thinking.
            if self.hasSession { self.end() }
            else { self.begin(isTap: true, sendOnFinish: false) }
        }
        hotkey.onEscape = { [weak self] in
            guard let self, self.hasSession || self.capture.isPrimed else { return }
            self.abort(nil)
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
        let configured = ["hotkey", "tapShortcut", "sendHotkey", "channel", "micUID"]
            .contains { defaults.object(forKey: $0) != nil }
        defaults.set(true, forKey: "didPromptAccessibility")
        guard !configured, !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.stop()
        PlaybackSilencer.shared.restoreAll()
    }

    private func primeRecording() {
        guard !recording, !HotkeyMonitor.paused else { return }
        try? capture.arm()
        enginePool.prewarm(dictation.isActive ? dictation.channel : Channel.current(in: defaults))
    }

    private func captureChanged(_ recording: Bool) {
        self.recording = recording
        if !recording {
            tapRecording = false
            if dictation.isActive {
                hud.showThinking()
            } else { hud.hide() }
        }
        setIcon(recording: recording)
    }

    func begin(isTap: Bool = false, sendOnFinish: Bool = false) {
        guard !recording else { return }
        do {
            guard try dictation.start(channel: Channel.current(in: defaults), sendsReturn: sendOnFinish) else { return }
        } catch {
            fail("麦克风启动失败：\(error.localizedDescription)")
            return
        }
        tapRecording = isTap
        hud.show(dictation.text, listening: true, clickToStop: isTap)
    }

    private func finishDictation(_ result: DictationSession.Result) {
        if let error = result.error {
            if !result.text.isEmpty { insertText(result.text, false) }
            let tail = result.text.isEmpty ? "" : "，已保留已识别的文字"
            fail("识别失败：\(error)\(tail)")
        } else if result.text.isEmpty {
            hud.show("没有识别到内容", listening: false)
            hud.hide(after: 1)
        } else {
            hud.hide()
            insertText(result.text, result.sendsReturn)
        }
    }

    func end() {
        guard recording else { capture.disarm(); return }
        if dictation.isActive {
            dictation.end()
        }
    }

    private func abort(_ message: String?) {
        capture.disarm()
        if dictation.isActive { dictation.cancel(message) }
        else { hud.hide() }
    }

    private func fail(_ message: String) {
        hud.show(message, listening: false)
        hud.hide(after: 2.5)
    }

    private func setIcon(recording: Bool) {
        statusItem?.button?.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "OpenVoice")
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
            alert.messageText = "下载本地模型？"
            alert.informativeText = "将下载约 185MB 的本地引擎库和模型，之后可随时在设置中删除。"
            alert.addButton(withTitle: "下载")
            alert.addButton(withTitle: "取消")

            if alert.runModal() == .alertFirstButtonReturn {
                OfflineAssets.shared.download()
            } else {
                UserDefaults.standard.set(previous, forKey: "channel")
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow?.contentView == nil {
            settingsWindow = SettingsWindow()
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
