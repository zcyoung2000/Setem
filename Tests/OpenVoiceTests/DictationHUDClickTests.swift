import AppKit
import XCTest
@testable import OpenVoice

@MainActor
final class DictationHUDClickTests: XCTestCase {
    @MainActor private final class Rig {
        let suite = "OpenVoice-HUDClick-" + UUID().uuidString
        let defaults: UserDefaults
        let hardware = ParityCapture()
        let hud: HUD
        var engines: [ParityEngine] = []
        var inserted: [(String, Bool)] = []
        lazy var app = AppDelegate(
            capture: DictationCapture(start: hardware.start, stop: hardware.stop),
            enginePool: DictationEnginePool { [unowned self] _ in
                let engine = ParityEngine(); engines.append(engine); return engine
            }, hud: hud, defaults: defaults,
            failoverPolicy: nil, insertText: { [unowned self] in inserted.append(($0, $1)) })
        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set("wetype", forKey: "channel")
            hud = HUD(defaults: defaults, reduceMotion: { true })
        }
        func close() {
            app.dictation.cancel(); hardware.close(); engines.forEach { $0.close() }
            hud.hide(); defaults.removePersistentDomain(forName: suite)
        }
    }

    private func mouse(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    private func click(_ hud: HUD, at point: NSPoint? = nil) throws {
        let window = hud.windowForDiagnostics
        let content = try XCTUnwrap(window.contentView)
        let location = point ?? NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        guard !window.ignoresMouseEvents else { XCTFail("Tap recording must accept a HUD click"); return }
        XCTAssertTrue(content.hitTest(location) === content, "The complete HUD must handle the click before its text/hosting views")
        window.sendEvent(try mouse(.leftMouseDown, in: window, at: location))
        window.sendEvent(try mouse(.leftMouseUp, in: window, at: location))
    }

    func testClickStopsTapCaptureImmediatelyKeepsFocusAndWaitsForExactFinal() async throws {
        _ = NSApplication.shared
        let rig = Rig()
        defer { rig.close() }
        let target = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 260, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        target.contentView = input
        target.makeKeyAndOrderFront(nil)
        XCTAssertTrue(target.makeFirstResponder(input))
        defer { target.orderOut(nil) }
        let originalKey = NSApplication.shared.keyWindow
        rig.app.begin(isTap: true)
        try await parityEventually { rig.engines.first?.rounds.count == 1 }
        rig.hardware.send(101)
        rig.engines[0].rounds[0].partial("临时稿，缺少尾字")
        try await parityEventually { rig.app.dictation.text == "临时稿，缺少尾字" }
        rig.hardware.tail = 102
        let window = rig.hud.windowForDiagnostics
        let content = try XCTUnwrap(window.contentView)
        let down = try mouse(.leftMouseDown, in: window, at: NSPoint(x: content.bounds.midX, y: content.bounds.midY))
        XCTAssertTrue(content.acceptsFirstMouse(for: down))
        try click(rig.hud)
        XCTAssertFalse(rig.app.dictation.isRecording, "Stop before waiting for another run-loop turn")
        XCTAssertEqual(rig.hardware.stops, 1)
        XCTAssertTrue(rig.app.dictation.isActive, "Continue recognizing the captured audio")
        XCTAssertTrue(rig.inserted.isEmpty)
        XCTAssertTrue(rig.hud.isVisible)
        XCTAssertTrue(window.ignoresMouseEvents, "Thinking cannot stop or cancel again")
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(target.firstResponder === input)
        XCTAssertTrue(NSApplication.shared.keyWindow === originalKey)
        try await parityEventually { rig.engines[0].rounds[0].ended }
        XCTAssertEqual(rig.engines[0].rounds[0].samples, [101, 102])
        rig.engines[0].rounds[0].resolve(.success("完整润色定稿，保留最后一个尾字。"))
        try await parityEventually { rig.inserted.count == 1 }
        XCTAssertEqual(rig.inserted[0].0, "完整润色定稿，保留最后一个尾字。")
        XCTAssertFalse(rig.inserted[0].1)
        XCTAssertFalse(rig.hud.isVisible)
    }

    func testEveryTapHUDRegionAndAccessibilityCanStopOnlyOnce() async throws {
        _ = NSApplication.shared
        for location in [NSPoint(x: 12, y: 12), NSPoint(x: 80, y: 40)] {
            let rig = Rig()
            defer { rig.close() }
            rig.app.begin(isTap: true)
            try await parityEventually { rig.engines.first?.rounds.count == 1 }
            try click(rig.hud, at: location)
            XCTAssertFalse(rig.app.dictation.isRecording)
            let content = try XCTUnwrap(rig.hud.windowForDiagnostics.contentView)
            XCTAssertFalse(content.accessibilityPerformPress())
            XCTAssertEqual(rig.hardware.stops, 1)
        }
        let rig = Rig()
        defer { rig.close() }
        rig.app.begin(isTap: true)
        let content = try XCTUnwrap(rig.hud.windowForDiagnostics.contentView)
        XCTAssertTrue(content.accessibilityPerformPress())
        XCTAssertFalse(content.accessibilityPerformPress())
        XCTAssertEqual(rig.hardware.stops, 1)
    }

    func testHoldAndThinkingIgnoreClicksAndResumeKeepsOlderFinal() async throws {
        _ = NSApplication.shared
        let rig = Rig()
        defer { rig.close() }
        rig.app.begin()
        try await parityEventually { rig.engines.first?.rounds.count == 1 }
        let window = rig.hud.windowForDiagnostics
        let content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(content.accessibilityPerformPress())
        XCTAssertTrue(rig.app.dictation.isRecording)
        rig.app.end()
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(content.accessibilityPerformPress())
        rig.app.begin(isTap: true)
        try await parityEventually { rig.engines.count == 2 && rig.engines[1].rounds.count == 1 }
        // A mouse-up belonging to the previous recording cannot end the resumed run.
        window.sendEvent(try mouse(.leftMouseUp, in: window, at: NSPoint(x: 20, y: 20)))
        XCTAssertTrue(rig.app.dictation.isRecording)
        rig.engines[0].rounds[0].resolve(.success("第一段完整润色。"))
        try await parityEventually { rig.app.dictation.text == "第一段完整润色。" }
        XCTAssertTrue(rig.app.dictation.isRecording)
        XCTAssertFalse(window.ignoresMouseEvents)
        try click(rig.hud)
        rig.engines[1].rounds[0].resolve(.success("第二段完整润色。"))
        try await parityEventually { rig.inserted.count == 1 }
        XCTAssertEqual(rig.inserted[0].0, "第一段完整润色。第二段完整润色。")
        XCTAssertEqual(rig.hardware.stops, 2)
    }
}
