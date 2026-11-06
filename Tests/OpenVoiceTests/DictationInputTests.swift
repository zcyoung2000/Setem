import AppKit
import XCTest
@testable import OpenVoice

@MainActor
final class DictationInputTests: XCTestCase {
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
