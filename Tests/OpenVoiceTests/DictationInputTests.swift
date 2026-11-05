import AppKit
import XCTest
@testable import OpenVoice

@MainActor
final class DictationInputTests: XCTestCase {
    func testPickerPanelCanReceiveKeysWithoutGlobalHookAndCannotReopenAfterHide() async throws {
        _ = NSApplication.shared
        let hud = PickHUD()
        let window = hud.windowForDiagnostics
        XCTAssertTrue(window.canBecomeKey, "Secure input requires the panel to receive keys without the global hook")
        var selected: [Channel] = [], chosen: [Channel] = [], digits: [Int] = []
        hud.onSelectionChange = { selected.append($0) }
        hud.onChoose = { chosen.append($0) }
        hud.onDigit = { digits.append($0) }
        hud.show([PickItem(channel: .doubao, text: "完整甲。", status: "完成"),
                  PickItem(channel: .wetype, text: "完整乙。", status: "完成")], anchor: nil, selected: 1)
        hud.hide() // Invalidate the pending main-queue show before it can order front.
        for code: UInt16 in [126, 36, 19] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            window.contentView?.keyDown(with: event)
        }
        XCTAssertEqual(selected, [.doubao])
        XCTAssertEqual(chosen, [.doubao])
        XCTAssertEqual(digits, [2])
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertFalse(hud.isVisible)
    }

    private func holdEvent(_ pressed: Bool) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 61, keyDown: pressed))
        event.type = .flagsChanged
        event.flags = pressed ? .maskAlternate : []
        return event
    }

    private func rendered(_ events: [CGEvent]) -> String {
        var text = ""
        for event in events where event.type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 51 { text.removeLast() }
            else {
                var units = [UniChar](repeating: 0, count: 20), length = 0
                event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                text += String(decoding: units.prefix(length), as: UTF16.self)
            }
        }
        return text
    }

    func testHotkeyCaptureSessionAndPolishedInputWorkTogether() async throws {
        let wasPaused = HotkeyMonitor.paused
        HotkeyMonitor.paused = false
        let hardware = ParityCapture()
        let capture = DictationCapture(start: hardware.start, stop: hardware.stop)
        let engine = ParityEngine()
        let model = DictationSession(startCapture: capture.take, stopCapture: capture.stop, makeEngine: { _ in engine })
        var events: [CGEvent] = [], fires: [() -> Void] = [], delays: [TimeInterval] = []
        let typer = StreamTyper(post: { events.append($0) })
        var result: DictationSession.Result?
        model.onUpdate = { typer.update($0) }
        model.onFinish = { result = $0; typer.update($0.text); typer.finish() }
        let monitor = HotkeyMonitor(configuration: { .init(hold: .rightOption, send: .rightControl, tap: nil, meeting: nil) },
                                    scheduleHold: { delay, fire in
            delays.append(delay); fires.append(fire)
            return Timer(timeInterval: delay, repeats: false) { _ in }
        })
        monitor.onPress = { do { try capture.arm() } catch { XCTFail("Pre-roll failed: \(error)") } }
        monitor.onCancel = { capture.disarm() }
        monitor.onLongPress = { _ in
            do { try model.start(channel: .wetype) } catch { XCTFail("Confirmed recording failed: \(error)") }
        }
        monitor.onRelease = { _ in model.end() }
        defer { model.cancel(); hardware.close(); engine.close(); HotkeyMonitor.paused = wasPaused }
        _ = monitor.handle(.flagsChanged, try holdEvent(true))
        XCTAssertTrue(capture.isPrimed)
        XCTAssertFalse(model.isRecording)
        hardware.send(101)
        try await parityEventually { hardware.sources[0].requests == 2 }
        XCTAssertEqual(delays, [0.3])
        fires[0]()
        try await parityEventually { engine.rounds.count == 1 }
        hardware.send(102)
        engine.rounds[0].partial("通知张经")
        try await parityEventually { model.text == "通知张经" }
        hardware.tail = 103
        _ = monitor.handle(.flagsChanged, try holdEvent(false))
        try await parityEventually { engine.rounds[0].ended }
        XCTAssertEqual(engine.rounds[0].samples, [101, 102, 103])
        XCTAssertNil(result)
        engine.rounds[0].resolve(.success("通知张经理，带上完整测试报告。"))
        try await parityEventually { result != nil }
        XCTAssertEqual(result?.text, "通知张经理，带上完整测试报告。")
        XCTAssertEqual(rendered(events), result?.text)
        XCTAssertEqual(hardware.stops, 1)
    }

    func testCancelledHoldCannotConfirmNextPress() throws {
        let wasPaused = HotkeyMonitor.paused
        HotkeyMonitor.paused = false
        let hardware = ParityCapture()
        defer { hardware.close(); HotkeyMonitor.paused = wasPaused }
        let capture = DictationCapture(start: hardware.start, stop: hardware.stop)
        var fires: [() -> Void] = [], confirmations = 0
        let monitor = HotkeyMonitor(configuration: { .init(hold: .rightOption, send: .rightControl, tap: nil, meeting: nil) },
                                    scheduleHold: { delay, fire in
            fires.append(fire)
            return Timer(timeInterval: delay, repeats: false) { _ in }
        })
        monitor.onPress = { do { try capture.arm() } catch { XCTFail("Pre-roll failed: \(error)") } }
        monitor.onCancel = { capture.disarm() }
        monitor.onLongPress = { _ in confirmations += 1 }
        _ = monitor.handle(.flagsChanged, try holdEvent(true))
        _ = monitor.handle(.flagsChanged, try holdEvent(false))
        XCTAssertFalse(capture.isPrimed)
        XCTAssertEqual(hardware.stops, 1)
        _ = monitor.handle(.flagsChanged, try holdEvent(true))
        XCTAssertTrue(capture.isPrimed)
        fires[0]() // Already-enqueued callback from the cancelled first press.
        XCTAssertEqual(confirmations, 0)
        fires[1]()
        XCTAssertEqual(confirmations, 1)
        _ = monitor.handle(.flagsChanged, try holdEvent(false))
    }

    func testStreamTyperEmitsCompletePolishedTextAndFreezesOnFinish() {
        var events: [CGEvent] = []
        let typer = StreamTyper(post: { events.append($0) })
        let interim = "明天三点不对四点开会，通知张经"
        let polished = "明天四点开会，通知张经理，并请所有同事带上已经完成的完整测试报告。"
        typer.update(interim)
        typer.update(polished)
        typer.finish()
        let count = events.count
        typer.update("迟到且缺尾字")
        XCTAssertEqual(events.count, count)
        var rendered = ""
        for event in events {
            XCTAssertEqual(event.flags, [])
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), DictationEvents.marker)
            guard event.type == .keyDown else { continue }
            if event.getIntegerValueField(.keyboardEventKeycode) == 51 { rendered.removeLast() }
            else {
                var units = [UniChar](repeating: 0, count: 20)
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                XCTAssertGreaterThan(length, 0)
                rendered += String(decoding: units.prefix(length), as: UTF16.self)
            }
        }
        XCTAssertEqual(rendered, polished)
        XCTAssertTrue(rendered.hasSuffix("完整测试报告。"))
        XCTAssertEqual(events.filter { $0.type == .keyDown }.count, events.filter { $0.type == .keyUp }.count)
    }

    func testSyntheticEventsCannotTriggerPicker() throws {
        let monitor = HotkeyMonitor()
        var picks: [PickKey] = []
        monitor.onPickKey = { picks.append($0); return true }
        let source = CGEventSource(stateID: .privateState)
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: DictationEvents.marker)
        XCTAssertFalse(monitor.handle(.keyDown, event))
        XCTAssertTrue(picks.isEmpty)
        let human = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 36, keyDown: true))
        XCTAssertNotEqual(human.getIntegerValueField(.eventSourceUserData), DictationEvents.marker)
        XCTAssertEqual(human.getIntegerValueField(.keyboardEventKeycode), 36)
        XCTAssertTrue(monitor.handle(.keyDown, human))
        XCTAssertEqual(picks, [.enter])
        let codes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        XCTAssertEqual(codes.compactMap(PickKey.from), (1...9).map(PickKey.digit))
        XCTAssertNil(PickKey.from(0))
    }
}
