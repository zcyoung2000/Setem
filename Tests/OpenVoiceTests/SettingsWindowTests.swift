import AppKit
import SwiftUI
import XCTest
@testable import OpenVoice

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testPlaybackMuteSwitchPersistsAndCanBeDisabledAfterReopening() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-EchoSettings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: Recorder.mutePlaybackKey))
        let window = SettingsWindow(defaults: defaults)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(window)
        try press("声音与界面", in: window)
        try await settle(window)
        try press("录音时静音电脑声音", in: window)
        try await settle(window)
        XCTAssertTrue(defaults.bool(forKey: Recorder.mutePlaybackKey))
        window.close()
        let reopened = SettingsWindow(defaults: defaults)
        defer { reopened.close() }
        reopened.makeKeyAndOrderFront(nil)
        try await settle(reopened)
        try press("声音与界面", in: reopened)
        try await settle(reopened)
        XCTAssertTrue(defaults.bool(forKey: Recorder.mutePlaybackKey))
        try press("录音时静音电脑声音", in: reopened)
        try await settle(reopened)
        XCTAssertFalse(defaults.bool(forKey: Recorder.mutePlaybackKey))
    }

    func testHotkeyPageRemovesSilenceControlsAndRetiredPreferencesOnReopen() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-ManualStopSettings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "silenceStop")
        defaults.set(1.0, forKey: "silence")
        for _ in 0..<2 {
            let window = SettingsWindow(defaults: defaults)
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            try await settle(window)
            try press("快捷键", in: window)
            try await settle(window)
            let visibleLabels = elements(in: window).flatMap { titles($0) + [label($0)].compactMap { $0 } }
            XCTAssertFalse(visibleLabels.contains { $0.contains("停顿自动结束") || $0.contains("静音时长") })
            XCTAssertNil(defaults.object(forKey: "silenceStop"))
            XCTAssertNil(defaults.object(forKey: "silence"))
            try press("点按快捷键", in: window)
            XCTAssertTrue(HotkeyMonitor.paused, "The remaining shortcut recorder still works")
            window.close()
            try await settle(window)
            XCTAssertFalse(HotkeyMonitor.paused)
        }
    }

    private func nativeViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { nativeViews(in: $0) }
    }

    func testFocusedNativeTabsDoNotDrawAnExteriorFocusRing() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-SettingsFocus-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<2 {
            let window = SettingsWindow(defaults: defaults)
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            try await settle(window)
            let labels = ["识别渠道", "快捷键", "声音与界面", "权限"]
            for (index, tab) in SettingsTab.allCases.enumerated() {
                try press(labels[index], in: window)
                try await settle(window)
                let root = try XCTUnwrap(window.contentView?.superview)
                let tabs = try XCTUnwrap(nativeViews(in: root).compactMap { $0 as? NSSegmentedControl }.first {
                    $0.segmentCount == SettingsTab.allCases.count
                })
                XCTAssertTrue(tabs.acceptsFirstResponder)
                XCTAssertTrue(window.makeFirstResponder(tabs))
                XCTAssertTrue(window.firstResponder === tabs)
                if #available(macOS 26.0, *) {
                    XCTAssertTrue(tabs.focusRingType == .none || tabs.focusRingType == .default)
                } else {
                    XCTAssertEqual(tabs.focusRingType, .none)
                }
                XCTAssertEqual(tabs.selectedSegment, index)
                XCTAssertEqual(window.navigation.tab, tab)
            }
        }
    }

    func testComparisonSheetStillClosesWithEscapeAfterFocusingControls() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-CompareFocus-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = SettingsWindow(defaults: defaults)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        try press("渠道对比", in: window)
        try await settle(window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        let control = try XCTUnwrap(
            nativeViews(in: content).first { $0.acceptsFirstResponder }
                ?? sheet.firstResponder as? NSView
                ?? sheet,
            "No focusable sheet content was available"
        )
        XCTAssertTrue(sheet.makeFirstResponder(control))
        XCTAssertTrue(sheet.firstResponder === control)
        sheet.sendEvent(try keyEvent("\u{1B}", code: 53, in: sheet))
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
    }

    func testShortcutFieldRecordsModifierTapAndModifiedKey() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-ShortcutRecording-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); HotkeyMonitor.paused = false }
        let window = SettingsWindow(defaults: defaults)
        window.makeKeyAndOrderFront(nil)
        window.navigation.tab = .hotkey
        try await settle(window)

        try press("快捷键", in: window)
        try await settle(window)
        try press("点按快捷键", in: window)
        XCTAssertTrue(HotkeyMonitor.paused)

        NSApp.sendEvent(try flagsChanged(55, pressed: true, in: window))
        NSApp.sendEvent(try flagsChanged(55, pressed: false, in: window))
        XCTAssertEqual(defaults.string(forKey: "tapShortcut"), Shortcut(keyCode: 55, modifiers: 0, name: "左 ⌘").raw)
        XCTAssertFalse(HotkeyMonitor.paused)

        try press("点按快捷键", in: window)
        NSApp.sendEvent(try flagsChanged(55, pressed: true, in: window))
        NSApp.sendEvent(try keyEvent("m", code: 46, modifiers: [.command], in: window))
        XCTAssertEqual(
            defaults.string(forKey: "tapShortcut"),
            Shortcut(keyCode: 46, modifiers: CGEventFlags([.maskCommand]).rawValue, name: "M").raw
        )
        XCTAssertFalse(HotkeyMonitor.paused)
        window.close()
    }

    private func keyEvent(_ characters: String, code: UInt16,
                          modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    private func flagsChanged(_ code: UInt16, pressed: Bool, in window: NSWindow) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed))
        cgEvent.flags = pressed ? (code == 55 ? .maskCommand : .maskAlternate) : []
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }


    private func attribute(_ name: String, of element: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func elements(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = [root]
        for child in attribute("accessibilityChildren", of: root) as? [NSObject] ?? [] {
            if child !== root {
                let element = child
                result.append(contentsOf: elements(in: element))
            }
        }
        return result
    }

    private func label(_ element: NSObject) -> String? {
        if let text = attribute("accessibilityLabel", of: element) as? String
            ?? attribute("accessibilityTitle", of: element) as? String { return text }
        if let title = attribute("accessibilityTitleUIElement", of: element) as? NSObject {
            return attribute("accessibilityValue", of: title) as? String
        }
        return nil
    }

    private func titles(_ element: NSObject) -> [String] {
        let values = [
            attribute("accessibilityLabel", of: element) as? String,
            attribute("accessibilityTitle", of: element) as? String,
        ]
        return values.compactMap { $0 }
    }

    private func role(_ element: NSObject) -> String? {
        attribute("accessibilityRole", of: element) as? String
    }

    private func boolean(_ name: String, of element: NSObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return false }
        let method = unsafeBitCast(element.method(for: selector),
                                   to: (@convention(c) (NSObject, Selector) -> Bool).self)
        return method(element, selector)
    }

    private func press(_ label: String, in window: NSWindow) throws {
        let button = try XCTUnwrap(elements(in: window).first {
            let labels = self.titles($0) + [self.label($0)].compactMap { $0 }
            let matchesLabel = labels.contains(label) || labels.contains {
                $0 == label || $0.hasSuffix("、" + label) || $0.hasSuffix(", " + label)
            }
            let roles = [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.radioButton.rawValue,
                         NSAccessibility.Role.checkBox.rawValue, "AXSwitch"]
            return matchesLabel && roles.contains(role($0) ?? "")
        }, "Missing button: \(label). \(elements(in: window).map { "\(role($0) ?? "-"):\(self.label($0) ?? "-")" })")
        if let control = button as? NSSwitch {
            control.performClick(nil)
        } else if !boolean("accessibilityPerformPress", of: button) {
            button.accessibilityPerformAction(.press)
        }
    }

    private func settle(_ window: NSWindow) async throws {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func testTabsKeepSettingsAndResizeWithoutMovingWindowTop() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-Settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wetype", forKey: "channel")
        defaults.set(HUDStyle.compact.rawValue, forKey: "hudStyle")
        let window = SettingsWindow(defaults: defaults)
        window.orderFrontRegardless()
        defer { window.close() }
        try await settle(window)
        let top = window.frame.maxY
        let initialHeight = window.frame.height

        try press("声音与界面", in: window)
        try await settle(window)

        XCTAssertFalse(elements(in: window).contains { label($0)?.contains("边说边上屏") == true })
        let style = try XCTUnwrap(nativeViews(in: XCTUnwrap(window.contentView)).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == HUDStyle.allCases.count })
        style.selectedSegment = 1
        _ = style.sendAction(style.action, to: style.target)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: "hudStyle"), HUDStyle.standard.rawValue)
        XCTAssertLessThan(window.frame.height, initialHeight)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)

        try press("识别渠道", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: "channel"), "wetype")
        XCTAssertEqual(defaults.string(forKey: "hudStyle"), HUDStyle.standard.rawValue)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialHeight, accuracy: 1)
    }

    func testLegacyMultiSelectionMigratesAndOnlySingleChannelsRemain() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-SingleChannelSettings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("all", forKey: "channel")
        defaults.set(["doubao", "wetype"], forKey: "multi")
        let window = SettingsWindow(defaults: defaults)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: "channel"), "doubao")
        XCTAssertNil(defaults.object(forKey: "multi"))
        XCTAssertFalse(elements(in: window).contains { label($0)?.contains("多渠道") == true })
        XCTAssertEqual(Channel.available, Channel.engines)
        try press("微信输入法", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: "channel"), "wetype")
    }

    func testNativeSizeChoiceUpdatesTheVisibleHUDAndPersistsOnReopen() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-LiveHUDSize-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(HUDStyle.compact.rawValue, forKey: "hudStyle")
        let window = SettingsWindow(defaults: defaults)
        let hud = HUD(defaults: defaults, reduceMotion: { true })
        defer { hud.hide(); window.close(); defaults.removePersistentDomain(forName: suite) }
        window.navigation.tab = .audio
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        hud.show("浮窗大小切换应立即应用到实际窗口。", listening: true)
        let compact = hud.windowForDiagnostics.frame.size
        try press("标准", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: "hudStyle"), HUDStyle.standard.rawValue)
        try await parityEventually { hud.windowForDiagnostics.frame.width > compact.width + 40 }
        let standard = hud.windowForDiagnostics.frame.size
        try press("紧凑", in: window)
        try await settle(window)
        try await parityEventually { abs(hud.windowForDiagnostics.frame.width - compact.width) < 1 }
        XCTAssertGreaterThan(standard.width, compact.width)
        window.close()
        let reopened = SettingsWindow(defaults: defaults)
        defer { reopened.close() }
        reopened.navigation.tab = .audio
        reopened.makeKeyAndOrderFront(nil)
        try await settle(reopened)
        XCTAssertEqual(defaults.string(forKey: "hudStyle"), HUDStyle.compact.rawValue)
        try press("标准", in: reopened)
        try await settle(reopened)
        try await parityEventually { abs(hud.windowForDiagnostics.frame.width - standard.width) < 1 }
    }

    func testTrailingPunctuationSwitchPersistsAndCanBeTurnedOffAfterReopening() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-OutputSetting-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = SettingsWindow(defaults: defaults)
        window.navigation.tab = .audio
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        XCTAssertFalse(defaults.bool(forKey: DictationOutput.removeTrailingPunctuationKey))
        try press("去除末尾标点", in: window)
        try await settle(window)
        XCTAssertTrue(defaults.bool(forKey: DictationOutput.removeTrailingPunctuationKey))
        XCTAssertEqual(DictationOutput.textForInsertion("你好。", defaults: defaults), "你好")
        window.close()
        let reopened = SettingsWindow(defaults: defaults)
        defer { reopened.close() }
        reopened.navigation.tab = .audio
        reopened.makeKeyAndOrderFront(nil)
        try await settle(reopened)
        XCTAssertTrue(defaults.bool(forKey: DictationOutput.removeTrailingPunctuationKey))
        try press("去除末尾标点", in: reopened)
        try await settle(reopened)
        XCTAssertFalse(defaults.bool(forKey: DictationOutput.removeTrailingPunctuationKey))
        XCTAssertEqual(DictationOutput.textForInsertion("你好。", defaults: defaults), "你好。")
    }

    func testLeavingShortcutPageAndClosingWindowReleaseKeyboardMonitor() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-ShortcutSettings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = SettingsWindow(defaults: defaults)
        window.orderFrontRegardless()
        defer { window.close(); HotkeyMonitor.paused = false }
        try await settle(window)
        try press("快捷键", in: window)
        try await settle(window)
        try press("点按快捷键", in: window)
        XCTAssertTrue(HotkeyMonitor.paused)

        try press("声音与界面", in: window)
        try await settle(window)
        XCTAssertFalse(HotkeyMonitor.paused)
        window.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(HotkeyMonitor.paused)
    }
}
