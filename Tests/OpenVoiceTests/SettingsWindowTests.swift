import AppKit
import XCTest
@testable import OpenVoice

@MainActor
final class SettingsWindowTests: XCTestCase {
    private func nativeViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { nativeViews(in: $0) }
    }

    func testFocusedNativeTabsDoNotDrawAnExteriorFocusRing() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-SettingsFocus-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<2 {
            let window = SettingsWindow(meeting: MeetingSession(), defaults: defaults)
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            try await settle(window)
            let labels = ["识别渠道", "快捷键", "会议转写", "声音与界面", "权限"]
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
                XCTAssertEqual(tabs.focusRingType, .none)
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
        let window = SettingsWindow(meeting: MeetingSession(), defaults: defaults)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        try press("渠道对比", in: window)
        try await settle(window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        let control = try XCTUnwrap(nativeViews(in: content).first { $0.acceptsFirstResponder })
        XCTAssertTrue(sheet.makeFirstResponder(control))
        XCTAssertTrue(sheet.firstResponder === control)
        sheet.sendEvent(try keyEvent("\u{1B}", code: 53, in: sheet))
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
    }

    private func keyEvent(_ characters: String, code: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
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
            (self.label($0) == label || self.label($0)?.hasSuffix("、" + label) == true)
                && [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.radioButton.rawValue].contains(role($0) ?? "")
        }, "Missing button: \(label). \(elements(in: window).map { "\(role($0) ?? "-"):\(self.label($0) ?? "-")" })")
        if !boolean("accessibilityPerformPress", of: button) {
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
        defaults.set(false, forKey: "streaming")
        let window = SettingsWindow(meeting: MeetingSession(), defaults: defaults)
        window.orderFrontRegardless()
        defer { window.close() }
        try await settle(window)
        let top = window.frame.maxY
        let initialHeight = window.frame.height

        try press("声音与界面", in: window)
        try await settle(window)

        let streaming = try XCTUnwrap(elements(in: window).first { label($0)?.contains("边说边上屏") == true },
                                     "\(elements(in: window).map { "\(role($0) ?? "-"):\(label($0) ?? "-")" })")
        XCTAssertEqual((attribute("accessibilityValue", of: streaming) as? NSNumber)?.boolValue, false)
        _ = boolean("accessibilityPerformPress", of: streaming)
        try await settle(window)
        XCTAssertTrue(defaults.bool(forKey: "streaming"))
        XCTAssertLessThan(window.frame.height, initialHeight)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)

        try press("识别渠道", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: "channel"), "wetype")
        XCTAssertTrue(defaults.bool(forKey: "streaming"))
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialHeight, accuracy: 1)
    }

    func testChannelSelectionPersistsAndMultiChannelKeepsAtLeastTwo() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-MultiSettings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["doubao", "wetype", "qwen"], forKey: "multi")
        let window = SettingsWindow(meeting: MeetingSession(), defaults: defaults)
        window.orderFrontRegardless()
        defer { window.close() }
        try await settle(window)
        try press("微信输入法", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: "channel"), "wetype")

        try press("多渠道（说完挑选）", in: window)
        try await settle(window)
        let qwen = try XCTUnwrap(elements(in: window).first {
            label($0) == "千问输入法" && role($0) == NSAccessibility.Role.checkBox.rawValue
        })
        XCTAssertTrue(boolean("accessibilityPerformPress", of: qwen))
        try await settle(window)
        XCTAssertEqual(defaults.stringArray(forKey: "multi"), ["doubao", "wetype"])
        let doubao = try XCTUnwrap(elements(in: window).first {
            label($0) == "豆包输入法" && role($0) == NSAccessibility.Role.checkBox.rawValue
        })
        XCTAssertFalse(boolean("isAccessibilityEnabled", of: doubao))
        XCTAssertEqual(defaults.string(forKey: "channel"), "all")

        try press("声音与界面", in: window)
        try await settle(window)
        let streaming = try XCTUnwrap(elements(in: window).first { label($0)?.contains("边说边上屏") == true },
                                     "\(elements(in: window).map { "\(role($0) ?? "-"):\(label($0) ?? "-")" })")
        XCTAssertFalse(boolean("isAccessibilityEnabled", of: streaming))
    }

    func testLeavingShortcutPageAndClosingWindowReleaseKeyboardMonitor() async throws {
        _ = NSApplication.shared
        let suite = "OpenVoice-ShortcutSettings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = SettingsWindow(meeting: MeetingSession(), defaults: defaults)
        window.orderFrontRegardless()
        defer { window.close(); HotkeyMonitor.paused = false }
        try await settle(window)
        try press("快捷键", in: window)
        try await settle(window)
        try press("点按快捷键", in: window)
        XCTAssertTrue(HotkeyMonitor.paused)

        try press("会议转写", in: window)
        try await settle(window)
        XCTAssertFalse(HotkeyMonitor.paused)
        try press("会议快捷键", in: window)
        XCTAssertTrue(HotkeyMonitor.paused)
        window.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(HotkeyMonitor.paused)
    }
}
