import AppKit
import XCTest
@testable import OpenVoice

/// Requirements and rendered UI outcomes: docs/dictation-hud-regression.md.
@MainActor
final class DictationHUDTests: XCTestCase {
    private struct RenderedHUD {
        let text: [String]
        let coloredPixels: Int
        let spinning: Bool
    }

    private func render(_ hud: HUD, save: String? = nil) async throws -> RenderedHUD {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let window = hud.windowForDiagnostics
        window.appearance = NSAppearance(named: .aqua)
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let save, let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: save))
        }
        var colored = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                let values = [color.redComponent, color.greenComponent, color.blueComponent]
                if values.max()! - values.min()! > 0.2 { colored += 1 }
            }
        }
        var labels: [String] = []
        var spinning = false
        var pending = [view]
        while let child = pending.popLast() {
            guard !child.isHiddenOrHasHiddenAncestor else { continue }
            if let label = child as? NSTextField { labels.append(label.stringValue) }
            if let progress = child as? NSProgressIndicator, progress.style == .spinning, progress.isIndeterminate {
                spinning = true
            }
            pending.append(contentsOf: child.subviews)
        }
        return RenderedHUD(text: labels, coloredPixels: colored, spinning: spinning)
    }

    private func assertWave(_ hud: HUD, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(hud.isVisible, file: file, line: line)
        let image = try await render(hud)
        XCTAssertGreaterThan(image.coloredPixels, 10, "The recording wave must actually render", file: file, line: line)
        XCTAssertFalse(image.spinning, file: file, line: line)
        XCTAssertFalse(image.text.contains("thinking"), file: file, line: line)
    }

    private func assertThinking(_ hud: HUD, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(hud.isVisible, file: file, line: line)
        let image = try await render(hud, save: "/tmp/openvoice-hud-thinking.png")
        XCTAssertTrue(image.text.contains("thinking"), "Rendered text: \(image.text)", file: file, line: line)
        XCTAssertEqual(image.coloredPixels, 0, "The recording wave must be removed while thinking", file: file, line: line)
        XCTAssertTrue(image.spinning, "Show the native loading indicator", file: file, line: line)
    }

    func testReleaseShowsThinkingUntilCompleteFinalAndTail() async throws {
        _ = NSApplication.shared
        for (channel, streaming) in [(Channel.doubao, false), (.doubao, true), (.wetype, false), (.wetype, true)] {
            let suite = "OpenVoice-ReleaseHUD-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(channel.rawValue, forKey: "channel")
            defaults.set(streaming, forKey: "streaming")
            defer { defaults.removePersistentDomain(forName: suite) }
            let hardware = ParityCapture()
            let engine = ParityEngine()
            let hud = HUD()
            var visibilityAtHardwareStop: [Bool] = []
            let capture = DictationCapture(start: hardware.start, stop: {
                visibilityAtHardwareStop.append(hud.isVisible)
                hardware.stop()
            })
            var inserted: [String] = [], events: [CGEvent] = []
            let app = AppDelegate(capture: capture, enginePool: DictationEnginePool { _ in engine }, hud: hud,
                                  defaults: defaults, insertText: { text, _ in inserted.append(text) },
                                  makeStreamTyper: { StreamTyper(post: { events.append($0) }) })
            defer { app.dictation.cancel(); hardware.close(); engine.close(); hud.hide() }
            app.begin()
            XCTAssertEqual(app.dictation.channel, channel)
            try await parityEventually { engine.rounds.count == 1 }
            try await assertWave(hud)
            hardware.send(101)
            hardware.send(102)
            engine.rounds[0].partial("明天三点不对四点开会，通知张经")
            try await parityEventually { app.dictation.text.hasSuffix("张经") }
            hardware.tail = 103

            app.end()

            XCTAssertTrue(hud.isVisible, "Retain the popup while finalization is pending")
            XCTAssertEqual(visibilityAtHardwareStop, [true])
            XCTAssertFalse(app.dictation.isRecording)
            XCTAssertTrue(app.dictation.isActive)
            XCTAssertTrue(inserted.isEmpty)
            try await assertThinking(hud)
            try await parityEventually { engine.rounds[0].ended }
            XCTAssertEqual(engine.rounds[0].samples, [101, 102, 103])
            engine.rounds[0].partial("明天四点开会，通知张经理")
            try await parityEventually { app.dictation.text.hasSuffix("张经理") }
            try await assertThinking(hud)
            engine.rounds[0].resolve(.success("明天四点开会，通知张经理，带上完整测试报告。"))
            try await parityEventually { !app.dictation.isActive }
            if streaming {
                XCTAssertTrue(inserted.isEmpty, "Streamed finalization must correct events instead of pasting a second copy")
                XCTAssertEqual(renderedDictationEvents(events), "明天四点开会，通知张经理，带上完整测试报告。")
            } else {
                XCTAssertEqual(inserted, ["明天四点开会，通知张经理，带上完整测试报告。"])
                XCTAssertTrue(events.isEmpty)
            }
            XCTAssertFalse(engine.rounds[0].wasCancelled)
            XCTAssertFalse(hud.isVisible, "The production completion handler must close the popup")
            XCTAssertEqual(hardware.stops, 1)
        }
    }

    func testSendPickerShowsThinkingUntilHealthyFinal() async throws {
        _ = NSApplication.shared
        let hardware = ParityCapture()
        let hud = HUD()
        var engines: [Channel: ParityEngine] = [:]
        let pool = DictationEnginePool { channel in
            let engine = ParityEngine(); engines[channel] = engine; return engine
        }
        let suite = "OpenVoice-ThinkingTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var inserted: [(String, Bool)] = []
        let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
                              enginePool: pool, hud: hud, defaults: defaults,
                              insertText: { inserted.append(($0, $1)) })
        defer {
            app.picker.cancel(); hardware.close(); engines.values.forEach { $0.close() }; hud.hide()
            defaults.removePersistentDomain(forName: suite)
        }
        try app.picker.start(channels: [.doubao, .wetype], sendsReturn: true)
        hud.show("", listening: true)
        try await parityEventually { engines.count == 2 && engines.values.allSatisfy { $0.rounds.count == 1 } }
        hardware.send(201)
        hardware.tail = 202
        app.end()
        XCTAssertTrue(hud.isVisible)
        XCTAssertFalse(app.picker.isRecording)
        XCTAssertTrue(app.picker.isActive)
        XCTAssertTrue(app.picker.rows.allSatisfy { $0.phase == .waiting })
        try await assertThinking(hud)
        try await parityEventually { engines.values.allSatisfy { $0.rounds[0].ended } }
        for engine in engines.values { XCTAssertEqual(engine.rounds[0].samples, [201, 202]) }
        let chosen = try XCTUnwrap(engines[.wetype])
        chosen.rounds[0].resolve(.success("完整定稿后只发送一次。"))
        try await parityEventually { inserted.count == 1 }
        XCTAssertEqual(inserted[0].0, "完整定稿后只发送一次。")
        XCTAssertTrue(inserted[0].1)
        XCTAssertFalse(hud.isVisible)
        XCTAssertFalse(app.picker.isActive)
        XCTAssertFalse(chosen.rounds[0].wasCancelled)
    }

    func testResumeReplacesThinkingWithWaveAndKeepsBothFinals() async throws {
        _ = NSApplication.shared
        let hardware = ParityCapture()
        let hud = HUD()
        var engines: [ParityEngine] = [], inserted: [String] = []
        let pool = DictationEnginePool { _ in let e = ParityEngine(); engines.append(e); return e }
        let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
                              enginePool: pool, hud: hud, insertText: { text, _ in inserted.append(text) })
        defer { app.dictation.cancel(); hardware.close(); engines.forEach { $0.close() }; hud.hide() }
        try app.dictation.start(channel: .wetype)
        hud.show("", listening: true)
        try await parityEventually { engines[0].rounds.count == 1 }
        app.end()
        try await assertThinking(hud)
        try app.dictation.start(channel: .wetype)
        hud.show(app.dictation.text, listening: true)
        try await parityEventually { engines.count == 2 && engines[1].rounds.count == 1 }
        try await assertWave(hud)
        engines[0].rounds[0].resolve(.success("上一段完整定稿。"))
        try await parityEventually { app.dictation.text == "上一段完整定稿。" }
        XCTAssertTrue(hud.isVisible)
        try await assertWave(hud)
        XCTAssertTrue(app.dictation.isRecording)
        app.end()
        try await assertThinking(hud)
        engines[1].rounds[0].resolve(.success("下一段完整尾字。"))
        try await parityEventually { inserted.count == 1 }
        XCTAssertEqual(inserted, ["上一段完整定稿。下一段完整尾字。"])
        XCTAssertFalse(hud.isVisible)
    }

    func testMessageHUDShowsTextWithoutWaveOrSpinner() async throws {
        _ = NSApplication.shared
        let hud = HUD()
        defer { hud.hide() }
        hud.show("没有识别到内容", listening: false)
        let image = try await render(hud)
        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(image.text, ["没有识别到内容"])
        XCTAssertEqual(image.coloredPixels, 0)
        XCTAssertFalse(image.spinning)
    }

    func testImmediateHUDHideCannotLaterHideResumedRecording() async {
        _ = NSApplication.shared
        let hud = HUD()
        defer { hud.hide() }
        hud.show("上一段", listening: true)
        XCTAssertTrue(hud.isVisible)
        hud.hide()
        XCTAssertFalse(hud.isVisible)
        hud.show("继续说", listening: true)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(hud.isVisible)
    }

    func testEmptyFinalHUDMatchesUpstreamStreamingMode() async throws {
        _ = NSApplication.shared
        for streaming in [true, false] {
            let suite = "OpenVoice-EmptyHUD-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set("wetype", forKey: "channel")
            defaults.set(streaming, forKey: "streaming")
            let hardware = ParityCapture(), engine = ParityEngine(), hud = HUD()
            var pasted: [String] = [], events: [CGEvent] = []
            let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
                enginePool: DictationEnginePool { _ in engine }, hud: hud, defaults: defaults,
                insertText: { text, _ in pasted.append(text) },
                makeStreamTyper: { StreamTyper(post: { events.append($0) }) })
            defer {
                app.dictation.cancel(); hardware.close(); engine.close(); hud.hide()
                defaults.removePersistentDomain(forName: suite)
            }
            app.begin()
            try await parityEventually { engine.rounds.count == 1 }
            app.end()
            try await assertThinking(hud)
            engine.rounds[0].resolve(.success(""))
            try await parityEventually { !app.dictation.isActive }
            XCTAssertTrue(pasted.isEmpty)
            XCTAssertTrue(events.isEmpty)
            if streaming {
                XCTAssertFalse(hud.isVisible, "Upstream closes a wholly empty streamed result immediately")
            } else {
                XCTAssertTrue(hud.isVisible)
                let image = try await render(hud)
                XCTAssertEqual(image.text, ["没有识别到内容"])
                XCTAssertFalse(image.spinning)
            }
        }
    }

    func testCancelledWaitingCallbacksCannotChangeNextRecordingHUD() async throws {
        _ = NSApplication.shared
        for failed in [true, false] {
            let hardware = ParityCapture(), hud = HUD()
            var engines: [ParityEngine] = [], inserted: [String] = []
            let pool = DictationEnginePool { _ in let engine = ParityEngine(); engines.append(engine); return engine }
            let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
                enginePool: pool, hud: hud, insertText: { text, _ in inserted.append(text) })
            defer { app.dictation.cancel(); hardware.close(); engines.forEach { $0.close() }; hud.hide() }
            try app.dictation.start(channel: .wetype)
            hud.show("", listening: true)
            try await parityEventually { engines.count == 1 && engines[0].rounds.count == 1 }
            app.end()
            try await assertThinking(hud)
            app.dictation.cancel()
            XCTAssertFalse(hud.isVisible)
            try app.dictation.start(channel: .wetype)
            hud.show("", listening: true)
            try await parityEventually { engines.count == 2 && engines[1].rounds.count == 1 }
            engines[0].rounds[0].partial("已取消的旧句")
            engines[0].rounds[0].resolve(failed ? .failure(ASRError("旧错误")) : .success("旧定稿"))
            try await parityEventually { engines[0].rounds[0].returned }
            try await assertWave(hud)
            XCTAssertTrue(app.dictation.isRecording)
            XCTAssertEqual(app.dictation.text, "")
            XCTAssertTrue(inserted.isEmpty)
            app.end()
            try await assertThinking(hud)
            engines[1].rounds[0].resolve(.success("新句保留完整尾字。"))
            try await parityEventually { inserted.count == 1 }
            XCTAssertEqual(inserted, ["新句保留完整尾字。"])
            XCTAssertFalse(hud.isVisible)
        }
    }

    func testThinkingIndicatorSurvivesMessageTransitions() async throws {
        _ = NSApplication.shared
        let hud = HUD()
        defer { hud.hide() }
        for _ in 0..<2 {
            hud.show("错误消息", listening: false)
            let message = try await render(hud)
            XCTAssertEqual(message.text, ["错误消息"])
            XCTAssertFalse(message.spinning)
            hud.showThinking()
            try await assertThinking(hud)
        }
    }

    func testDelayedMessageHideCannotCloseNewThinkingHUD() async throws {
        _ = NSApplication.shared
        let hud = HUD()
        defer { hud.hide() }
        hud.show("旧错误消息", listening: false)
        hud.hide(after: 0.01)
        hud.show("", listening: true)
        try await assertWave(hud)
        hud.showThinking()
        try await Task.sleep(for: .milliseconds(40))
        try await assertThinking(hud)
    }
}
