import AppKit
import XCTest
@testable import OpenVoice

@MainActor
final class DictationInputTests: XCTestCase {
    func testRepeatedTapStopsThenWaitsWithoutCancellingOrStartingAnotherSegment() async throws {
        _ = NSApplication.shared
        let wasPaused = HotkeyMonitor.paused
        HotkeyMonitor.paused = false
        defer { HotkeyMonitor.paused = wasPaused }
        for modifierTap in [false, true] {
            let suite = "OpenVoice-ManualTap-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set("wetype", forKey: "channel")
            defaults.set(true, forKey: "silenceStop")
            defaults.set(1.0, forKey: "silence")
            let shortcut = modifierTap ? Shortcut(keyCode: 55, modifiers: 0, name: "左 ⌘")
                : Shortcut(keyCode: 49, modifiers: CGEventFlags([.maskControl, .maskShift]).rawValue, name: "Space")
            let monitor = HotkeyMonitor(configuration: { .init(hold: .rightOption, send: .rightControl, tap: shortcut, meeting: nil) })
            let hardware = ParityCapture()
            let capture = DictationCapture(start: hardware.start, stop: hardware.stop)
            let hud = HUD(defaults: defaults, reduceMotion: { true })
            var engines: [ParityEngine] = []
            var inserted: [(String, Bool)] = []
            let app = AppDelegate(capture: capture,
                enginePool: DictationEnginePool { _ in let engine = ParityEngine(); engines.append(engine); return engine },
                hud: hud, defaults: defaults, hotkey: monitor, insertText: { inserted.append(($0, $1)) })
            defer {
                app.dictation.cancel(); hardware.close(); engines.forEach { $0.close() }; hud.hide()
                defaults.removePersistentDomain(forName: suite)
            }
            func tap() throws {
                for pressed in [true, false] {
                    let event = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState),
                        virtualKey: UInt16(shortcut.keyCode), keyDown: pressed))
                    event.flags = modifierTap ? (pressed ? .maskCommand : []) : [.maskControl, .maskShift]
                    let type: CGEventType = modifierTap ? .flagsChanged : (pressed ? .keyDown : .keyUp)
                    event.type = type
                    _ = monitor.handle(type, event)
                }
            }
            try tap()
            try await parityEventually { engines.first?.rounds.count == 1 }
            let first = engines[0].rounds[0]
            hardware.send(101)
            first.partial("已经说出的完整内容")
            try await parityEventually { app.dictation.text == "已经说出的完整内容" }
            hardware.tail = 102
            try tap()
            XCTAssertFalse(app.dictation.isRecording)
            XCTAssertTrue(app.dictation.isActive)
            XCTAssertEqual(hardware.stops, 1)
            XCTAssertTrue(inserted.isEmpty)
            try await parityEventually { first.ended }
            XCTAssertEqual(first.samples, [101, 102])
            let captures = hardware.sources.count
            let stops = hardware.stops
            try tap() // A repeated tap while thinking must leave this final pending.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
            XCTAssertFalse(app.dictation.isRecording)
            XCTAssertFalse(capture.isPrimed)
            XCTAssertEqual(hardware.sources.count, captures, "Thinking taps must not reopen the microphone")
            XCTAssertEqual(hardware.stops, stops)
            XCTAssertEqual(engines.flatMap(\.rounds).count, 1)
            XCTAssertTrue(inserted.isEmpty)
            first.resolve(.success("完整润色稿，保留最后一个尾字。"))
            try await parityEventually { inserted.count == 1 }
            XCTAssertEqual(inserted[0].0, "完整润色稿，保留最后一个尾字。")
            XCTAssertFalse(inserted[0].1)
            XCTAssertFalse(app.dictation.isActive)
        }
    }

    private func holdEvent(_ pressed: Bool) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 61, keyDown: pressed))
        event.type = .flagsChanged
        event.flags = pressed ? .maskAlternate : []
        return event
    }


    func testHotkeyCaptureSessionAndPolishedInputWorkTogether() async throws {
        let wasPaused = HotkeyMonitor.paused
        HotkeyMonitor.paused = false
        let hardware = ParityCapture()
        let capture = DictationCapture(start: hardware.start, stop: hardware.stop)
        let engine = ParityEngine()
        let model = DictationSession(startCapture: capture.take, stopCapture: capture.stop, makeEngine: { _ in engine })
        var inserted: [String] = [], fires: [() -> Void] = [], delays: [TimeInterval] = []
        var result: DictationSession.Result?
        model.onFinish = { result = $0; inserted.append($0.text) }
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
        XCTAssertTrue(inserted.isEmpty)
        engine.rounds[0].resolve(.success("通知张经理，带上完整测试报告。"))
        try await parityEventually { result != nil }
        XCTAssertEqual(result?.text, "通知张经理，带上完整测试报告。")
        XCTAssertEqual(inserted, ["通知张经理，带上完整测试报告。"])
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

    func testSyntheticEventsCannotTriggerDictationCancellation() throws {
        let monitor = HotkeyMonitor()
        var escapes = 0
        monitor.onEscape = { escapes += 1 }
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 53, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: DictationEvents.marker)
        XCTAssertFalse(monitor.handle(.keyDown, event))
        XCTAssertEqual(escapes, 0)
        let human = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 53, keyDown: true))
        _ = monitor.handle(.keyDown, human)
        XCTAssertEqual(escapes, 1)
    }
}
