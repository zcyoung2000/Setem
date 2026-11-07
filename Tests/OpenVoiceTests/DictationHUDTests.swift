import AppKit
import XCTest
@testable import OpenVoice

/// Requirements and rendered UI outcomes: docs/dictation-hud-regression.md.
@MainActor
final class DictationHUDTests: XCTestCase {
    func testPointSizedSurfaceNeverAssignsInfiniteChildFrames() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { true })
        defer { hud.hide() }
        hud.show("缩放过程仍保留完整文字。", listening: true)
        let surface = try XCTUnwrap(nativeView("dictation-surface", in: hud))
        let original = surface.bounds
        defer { surface.bounds = original; surface.needsLayout = true }
        for size: CGFloat in [8, 16, 24, 40] {
            surface.bounds = NSRect(x: 0, y: 0, width: size, height: size)
            surface.needsLayout = true
            surface.layoutSubtreeIfNeeded()
            for child in surface.subviews {
                XCTAssertTrue(child.frame.origin.x.isFinite && child.frame.origin.y.isFinite,
                    "\(type(of: child)) has invalid frame \(child.frame) at \(size)pt")
                XCTAssertTrue(child.frame.width.isFinite && child.frame.height.isFinite)
                XCTAssertGreaterThanOrEqual(child.frame.width, 0)
                XCTAssertGreaterThanOrEqual(child.frame.height, 0)
            }
        }
    }

    func testIdenticalPreviewDoesNotEditNativeTextStorageAgain() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { true })
        defer { hud.hide() }
        let value = "相同回包无需重新排版，完整尾字🧪。"
        hud.show(value, listening: true)
        let text = try XCTUnwrap(nativeView("dictation-preview-text", in: hud) as? NSTextView)
        let storage = try XCTUnwrap(text.textStorage)
        let frame = hud.windowForDiagnostics.frame
        var edits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<20 { hud.update(value) }
        XCTAssertEqual(edits, 0)
        XCTAssertEqual(text.string, value)
        XCTAssertEqual(hud.windowForDiagnostics.frame, frame)
        hud.showThinking()
        XCTAssertEqual(text.string, value)
        try await assertThinking(hud)
    }

    private struct RenderedHUD {
        let text: [String]
        let coloredPixels: Int
        let processing: Bool
        let audioWidth: CGFloat?
        let progressWidth: CGFloat?
    }

    private func render(_ hud: HUD, save: String? = nil) async throws -> RenderedHUD {
        // Allow SwiftUI's display transaction to publish native text and its new height.
        try await Task.sleep(for: .milliseconds(40))
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
        var labels: [String] = []
        var previewBounds: [NSRect] = []
        var processing = false
        var audioWidth: CGFloat?
        var progressWidth: CGFloat?
        var pending = [view]
        while let child = pending.popLast() {
            guard !child.isHiddenOrHasHiddenAncestor else { continue }
            if let label = child as? NSTextField { labels.append(label.stringValue) }
            if let preview = child as? NSTextView {
                labels.append(preview.string)
                if let scroll = preview.enclosingScrollView { previewBounds.append(scroll.convert(scroll.bounds, to: view)) }
            }
            if child.identifier?.rawValue == "dictation-audio-bars" { audioWidth = child.frame.width }
            if child.identifier?.rawValue == "dictation-thinking-progress" {
                processing = true
                progressWidth = child.frame.width
            }
            pending.append(contentsOf: child.subviews)
        }
        var colored = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let point = NSPoint(x: CGFloat(x) * view.bounds.width / CGFloat(bitmap.pixelsWide),
                                    y: CGFloat(y) * view.bounds.height / CGFloat(bitmap.pixelsHigh))
                let local = NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
                // Emoji may be colored; count only the area outside the transcript viewport.
                guard !previewBounds.contains(where: { $0.contains(local) }),
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                let values = [color.redComponent, color.greenComponent, color.blueComponent]
                if values.max()! - values.min()! > 0.2 { colored += 1 }
            }
        }
        return RenderedHUD(text: labels, coloredPixels: colored, processing: processing,
                           audioWidth: audioWidth, progressWidth: progressWidth)
    }

    private func assertWave(_ hud: HUD, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await settleScale(hud)
        try await parityEventually { self.nativeView("dictation-thinking", in: hud)?.isHidden == true }
        XCTAssertTrue(hud.isVisible, file: file, line: line)
        let image = try await render(hud)
        XCTAssertGreaterThan(image.coloredPixels, 10, "The recording wave must actually render", file: file, line: line)
        XCTAssertFalse(image.processing, file: file, line: line)
        XCTAssertFalse(image.text.contains("thinking"), file: file, line: line)
        XCTAssertGreaterThan(image.audioWidth ?? 0, hud.windowForDiagnostics.frame.width * 0.7, file: file, line: line)
    }

    private func assertThinking(_ hud: HUD, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await settleScale(hud)
        try await parityEventually { self.nativeView("dictation-audio-bars", in: hud)?.isHidden == true }
        XCTAssertTrue(hud.isVisible, file: file, line: line)
        let image = try await render(hud, save: "/tmp/openvoice-hud-thinking.png")
        XCTAssertTrue(image.text.contains("thinking"), "Rendered text: \(image.text)", file: file, line: line)
        XCTAssertNil(image.audioWidth, "The recording animation must be removed while thinking", file: file, line: line)
        XCTAssertTrue(image.processing, "Show the full-width indeterminate progress track", file: file, line: line)
        XCTAssertGreaterThan(image.progressWidth ?? 0, hud.windowForDiagnostics.frame.width * 0.7, file: file, line: line)
    }

    private func nativeView(_ identifier: String, in hud: HUD) -> NSView? {
        var pending = hud.windowForDiagnostics.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            if view.identifier?.rawValue == identifier { return view }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func assertHidden(_ hud: HUD, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await parityEventually { !hud.isVisible }
        XCTAssertFalse(hud.windowForDiagnostics.isVisible, file: file, line: line)
    }

    private func settleScale(_ hud: HUD) async throws {
        try await parityEventually {
            guard let surface = self.nativeView("dictation-surface", in: hud) else { return false }
            return abs(surface.bounds.width - surface.frame.width) < 0.5
                && abs(surface.bounds.height - surface.frame.height) < 0.5
        }
    }

    func testDismissalShrinksContentAndImmediateRecordingCancelsOldExit() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { false })
        defer { hud.hide() }
        hud.show("完整定稿，柔和结束。", listening: true)
        hud.showThinking()
        try await assertThinking(hud)
        let text = try XCTUnwrap(nativeView("dictation-preview-text", in: hud) as? NSTextView)
        let fullFrame = hud.windowForDiagnostics.frame
        hud.hide()
        XCTAssertTrue(hud.isVisible)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(hud.windowForDiagnostics.alphaValue, 1)
        XCTAssertLessThan(hud.windowForDiagnostics.frame.width, fullFrame.width)
        XCTAssertGreaterThan(hud.windowForDiagnostics.frame.width, 8)
        XCTAssertEqual(hud.windowForDiagnostics.frame.midX, fullFrame.midX, accuracy: 1)
        XCTAssertEqual(hud.windowForDiagnostics.frame.midY, fullFrame.midY, accuracy: 1)
        XCTAssertEqual(text.string, "完整定稿，柔和结束。", "Scale the last content during the exit")
        hud.update("退出期间迟到的旧文字")
        XCTAssertEqual(text.string, "完整定稿，柔和结束。")
        try await assertHidden(hud)
        hud.show("下一次录音", listening: true)
        hud.hide()
        try await Task.sleep(for: .milliseconds(60))
        hud.show("立即续录，旧退出不能关闭我。", listening: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(hud.windowForDiagnostics.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(text.string, "立即续录，旧退出不能关闭我。")
        try await assertWave(hud)
    }

    func testShortenedPreviewKeepsFirstLineVisibleThroughResizeAndThinking() async throws {
        _ = NSApplication.shared
        for style in HUDStyle.allCases {
            let suite = "OpenVoice-PreviewViewport-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(style.rawValue, forKey: "hudStyle")
            let hud = HUD(defaults: defaults, reduceMotion: { false })
            defer { hud.hide(); defaults.removePersistentDomain(forName: suite) }
            hud.show(Array(repeating: "这是用于检查浮窗整体缩放与文字排版的预览。", count: 10).joined(separator: "\n"), listening: true)
            try await Task.sleep(for: .milliseconds(400))
            let text = try XCTUnwrap(nativeView("dictation-preview-text", in: hud) as? NSTextView)
            let scroll = try XCTUnwrap(text.enclosingScrollView)
            for value in ["你好，文字只在浮窗里预览。", "你好，文字只在浮窗里预览。说完后等待润色，再一次性输入到目标输入框。"] {
                hud.update(value)
                XCTAssertEqual(text.string, value)
                for _ in 0..<18 {
                    try await Task.sleep(for: .milliseconds(33))
                    XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 0.5,
                        "\(style): first line must stay visible while resizing: \(text.frame), \(scroll.documentVisibleRect)")
                }
            }
            hud.showThinking()
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(33))
                XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 0.5,
                    "\(style): thinking must retain the first line: \(text.frame), \(scroll.documentVisibleRect)")
            }
        }
    }

    func testEntranceExpandsFromPointAndScalesWholeContent() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { false })
        defer { hud.hide() }
        hud.show("从小点张开，文字保持完整。", listening: true)
        let initial = hud.windowForDiagnostics.frame
        XCTAssertEqual(initial.size, NSSize(width: 8, height: 8))
        let text = try XCTUnwrap(nativeView("dictation-preview-text", in: hud) as? NSTextView)
        XCTAssertEqual(text.string, "从小点张开，文字保持完整。")
        try await Task.sleep(for: .milliseconds(80))
        let middle = hud.windowForDiagnostics.frame
        let surface = try XCTUnwrap(nativeView("dictation-surface", in: hud))
        XCTAssertGreaterThan(middle.width, initial.width)
        XCTAssertGreaterThan(surface.bounds.width, surface.frame.width, "Scale the complete surface rather than rewrapping text")
        XCTAssertEqual(hud.windowForDiagnostics.alphaValue, 1)
        try await settleScale(hud)
        let full = hud.windowForDiagnostics.frame
        XCTAssertGreaterThan(full.width, middle.width)
        XCTAssertEqual(full.midX, initial.midX, accuracy: 1)
        XCTAssertEqual(full.midY, initial.midY, accuracy: 1)
        XCTAssertEqual(text.string, "从小点张开，文字保持完整。")
        XCTAssertFalse(hud.windowForDiagnostics.isKeyWindow)
    }

    func testReleaseShowsThinkingUntilCompleteFinalAndTail() async throws {
        _ = NSApplication.shared
        for (channel, streaming) in Channel.engines.flatMap({ channel in [false, true].map { (channel, $0) } }) {
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
            var inserted: [String] = []
            let app = AppDelegate(capture: capture, enginePool: DictationEnginePool { _ in engine }, hud: hud,
                                  defaults: defaults, insertText: { text, _ in inserted.append(text) })
            defer { app.dictation.cancel(); hardware.close(); engine.close(); hud.hide() }
            app.begin()
            XCTAssertEqual(app.dictation.channel, channel)
            try await parityEventually { engine.rounds.count == 1 }
            try await assertWave(hud)
            hardware.send(101)
            hardware.send(102)
            engine.rounds[0].partial("明天三点不对四点开会，通知张经")
            try await parityEventually { app.dictation.text.hasSuffix("张经") }
            XCTAssertTrue(inserted.isEmpty)
            let listeningPreview = try await render(hud)
            XCTAssertTrue(listeningPreview.text.contains("明天三点不对四点开会，通知张经"))
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
            let waitingPreview = try await render(hud)
            XCTAssertTrue(waitingPreview.text.contains("明天四点开会，通知张经理"))
            XCTAssertTrue(inserted.isEmpty)
            engine.rounds[0].resolve(.success("明天四点开会，通知张经理，带上完整测试报告。"))
            try await parityEventually { !app.dictation.isActive }
            XCTAssertEqual(inserted, ["明天四点开会，通知张经理，带上完整测试报告。"])
            XCTAssertFalse(engine.rounds[0].wasCancelled)
            try await assertHidden(hud)
            XCTAssertEqual(hardware.stops, 1)
        }
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
        XCTAssertTrue(inserted.isEmpty)
        let continued = try await render(hud)
        XCTAssertTrue(continued.text.contains("上一段完整定稿。"))
        XCTAssertTrue(hud.isVisible)
        try await assertWave(hud)
        XCTAssertTrue(app.dictation.isRecording)
        app.end()
        try await assertThinking(hud)
        engines[1].rounds[0].resolve(.success("下一段完整尾字。"))
        try await parityEventually { inserted.count == 1 }
        XCTAssertEqual(inserted, ["上一段完整定稿。下一段完整尾字。"])
        try await assertHidden(hud)
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
        XCTAssertFalse(image.processing)
    }

    func testLongPreviewWrapsFollowsTailAndNeverTakesFocus() async throws {
        _ = NSApplication.shared
        let hud = HUD()
        defer { hud.hide() }
        let keyWindow = NSApp.keyWindow
        hud.show("短预览", listening: true)
        _ = try await render(hud)
        let shortHeight = hud.windowForDiagnostics.frame.height
        let text = String(repeating: "这是一段持续说话的长预览，需要换行显示，并保留已经识别的内容。\n", count: 30) + "𠮷野家 😀 完整尾字。"
        hud.update(text)
        try await parityEventually { hud.windowForDiagnostics.frame.height > shortHeight }
        let image = try await render(hud, save: "/tmp/openvoice-hud-long-preview.png")
        XCTAssertTrue(image.text.contains(text))
        XCTAssertGreaterThan(hud.windowForDiagnostics.frame.height, shortHeight)
        XCTAssertLessThan(hud.windowForDiagnostics.frame.height, 240)
        XCTAssertFalse(hud.windowForDiagnostics.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        var pending = [try XCTUnwrap(hud.windowForDiagnostics.contentView)]
        var preview: NSTextView?
        while let view = pending.popLast() {
            if let text = view as? NSTextView { preview = text; break }
            pending.append(contentsOf: view.subviews)
        }
        let nativeText = try XCTUnwrap(preview)
        let viewport = try XCTUnwrap(nativeText.enclosingScrollView)
        XCTAssertGreaterThan(viewport.contentView.bounds.minY, 0, "Long previews must follow their latest words")
        XCTAssertGreaterThan(nativeText.frame.height, viewport.contentSize.height)
        let manager = try XCTUnwrap(nativeText.layoutManager)
        let tail = manager.glyphRange(forCharacterRange: NSRange(location: text.utf16.count - 1, length: 1), actualCharacterRange: nil)
        let tailRect = manager.boundingRect(forGlyphRange: tail, in: try XCTUnwrap(nativeText.textContainer))
            .offsetBy(dx: nativeText.textContainerOrigin.x, dy: nativeText.textContainerOrigin.y)
        XCTAssertTrue(viewport.documentVisibleRect.contains(tailRect), "The final glyph must be visible: \(tailRect), \(viewport.documentVisibleRect)")
        XCTAssertFalse(nativeText.isEditable)
        hud.showThinking()
        try await assertThinking(hud)
        let waiting = try await render(hud)
        XCTAssertTrue(waiting.text.contains(text))
        hud.update("")
        let cleared = try await render(hud)
        XCTAssertEqual(cleared.text, ["thinking"], "Withdrawn partials must disappear from the preview")
    }

    func testExpansionEasesThroughNativeFramesAndActivityFollowsWidth() async throws {
        _ = NSApplication.shared
        for style in HUDStyle.allCases {
            let suite = "OpenVoice-HUDMotion-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(style.rawValue, forKey: "hudStyle")
            let hud = HUD(defaults: defaults, reduceMotion: { false })
            defer { hud.hide(); defaults.removePersistentDomain(forName: suite) }
            hud.show("", listening: true)
            try await settleScale(hud)
            let initial = hud.windowForDiagnostics.frame
            hud.update("你好，这段文字会在浮窗中预览，状态动画应随整个浮窗展开。")
            XCTAssertEqual(hud.windowForDiagnostics.frame, initial, "Expansion must not jump to its destination")
            var frames: [NSRect] = []
            for _ in 0..<28 {
                try await Task.sleep(for: .milliseconds(16))
                let frame = hud.windowForDiagnostics.frame
                frames.append(frame)
                XCTAssertEqual(frame.midX, initial.midX, accuracy: 1)
                XCTAssertEqual(frame.minY, initial.minY, accuracy: 1)
                let surface = try XCTUnwrap(hud.windowForDiagnostics.contentView)
                let glass = try XCTUnwrap(nativeView("dictation-backdrop", in: hud))
                XCTAssertEqual(glass.convert(glass.bounds, to: surface).width, frame.width, accuracy: 1, "The glass must follow every intermediate frame")
            }
            let expanded = hud.windowForDiagnostics.frame
            XCTAssertGreaterThan(expanded.width, initial.width)
            XCTAssertGreaterThanOrEqual(Set(frames.map { Int($0.width.rounded()) }).count, 4)
            let earlyProgress = (frames[5].width - initial.width) / (expanded.width - initial.width)
            XCTAssertGreaterThan(earlyProgress, 0.4, "Expansion must ease out instead of moving at constant speed")
            try await assertWave(hud)
            hud.showThinking()
            try await assertThinking(hud)
            XCTAssertEqual(hud.windowForDiagnostics.frame, expanded, "Changing state must keep the activity row height")
        }
    }

    func testResizeRetargetingAndHideCannotLeaveOldAnimationsRunning() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { false })
        defer { hud.hide() }
        hud.show("", listening: true)
        hud.update("开始预览")
        try await Task.sleep(for: .milliseconds(60))
        hud.update(String(repeating: "持续说话，完整预览。", count: 40))
        try await Task.sleep(for: .milliseconds(60))
        hud.showThinking()
        hud.show("继续录音的新内容", listening: true)
        try await Task.sleep(for: .milliseconds(420))
        let resumed = try await render(hud)
        XCTAssertTrue(resumed.text.contains("继续录音的新内容"))
        XCTAssertFalse(resumed.processing)
        hud.update(String(repeating: "下一段", count: 60))
        try await Task.sleep(for: .milliseconds(45))
        hud.hide()
        try await Task.sleep(for: .milliseconds(400))
        try await assertHidden(hud)
        XCTAssertEqual(hud.windowForDiagnostics.frame.size, NSSize(width: 8, height: 8))
        hud.show("取消后重新开始", listening: true)
        try await assertWave(hud)
    }

    func testReducedMotionAppliesFinalSizeWithoutResizeAnimation() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { true })
        defer { hud.hide() }
        hud.show("", listening: true)
        let initial = hud.windowForDiagnostics.frame
        hud.update("减少动态效果时直接展示完整文字预览")
        let final = hud.windowForDiagnostics.frame
        XCTAssertGreaterThan(final.width, initial.width)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(hud.windowForDiagnostics.frame, final)
        hud.showThinking()
        try await assertThinking(hud)
        let track = try XCTUnwrap(nativeView("dictation-thinking-progress", in: hud))
        XCTAssertNil(track.layer?.sublayers?.first?.animationKeys())
        let text = try XCTUnwrap(nativeView("dictation-preview-text", in: hud) as? NSTextView)
        XCTAssertNil(text.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
        hud.hide()
        XCTAssertFalse(hud.isVisible, "Reduced motion must skip the exit animation")
    }

    func testNewTextFadesWithoutFlashingStablePrefixOrDelayingUnicode() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { false })
        defer { hud.hide() }
        let prefix = "已经显示的文字"
        hud.show(prefix, listening: true)
        try await Task.sleep(for: .milliseconds(320))
        let text = try XCTUnwrap(nativeView("dictation-preview-text", in: hud) as? NSTextView)
        let manager = try XCTUnwrap(text.layoutManager)
        let expected = prefix + "，新文字 𠮷 👨‍👩‍👦 e\u{301} 完整尾字。"
        hud.update(expected)
        XCTAssertEqual(text.string, expected, "Animation must never delay the actual transcript")
        XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
        let initial = try XCTUnwrap(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: prefix.utf16.count, effectiveRange: nil) as? NSColor)
        XCTAssertLessThan(initial.alphaComponent, 0.4)
        try await Task.sleep(for: .milliseconds(100))
        let middle = try XCTUnwrap(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: prefix.utf16.count, effectiveRange: nil) as? NSColor)
        XCTAssertGreaterThan(middle.alphaComponent, initial.alphaComponent)
        hud.update(expected + "继续说。")
        let retained = try XCTUnwrap(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: prefix.utf16.count, effectiveRange: nil) as? NSColor)
        XCTAssertGreaterThanOrEqual(retained.alphaComponent, middle.alphaComponent, "The next update must not restart an existing fade")
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(text.string, expected + "继续说。")
        XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: prefix.utf16.count, effectiveRange: nil))

        hud.show("通知张经，保留完整尾字。", listening: true)
        try await Task.sleep(for: .milliseconds(320))
        hud.update("通知张经理，保留完整尾字。")
        let revision = text.string as NSString
        XCTAssertNotNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: revision.range(of: "理").location, effectiveRange: nil))
        XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: revision.range(of: "完整尾字").location, effectiveRange: nil))
        hud.show("𠮷é", listening: true)
        hud.update("开始𠮷e\u{301}")
        XCTAssertEqual(text.string, "开始𠮷e\u{301}", "Normalization changes must preserve valid native attribute ranges")
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
    }

    func testNewLinesGrowGraduallyAndWaveCrossfadesIntoThinking() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { false })
        defer { hud.hide() }
        hud.show("第一行文字。", listening: true)
        try await settleScale(hud)
        let initial = hud.windowForDiagnostics.frame
        hud.update("第一行文字。\n第二行逐渐出现。\n第三行完整尾字。")
        XCTAssertEqual(hud.windowForDiagnostics.frame, initial)
        var heights = [initial.height]
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(16))
            heights.append(hud.windowForDiagnostics.frame.height)
        }
        let final = hud.windowForDiagnostics.frame
        XCTAssertGreaterThan(final.height, initial.height)
        XCTAssertGreaterThan(Set(heights.map { Int($0.rounded()) }).count, 3, "New lines must pass through intermediate heights")
        XCTAssertEqual(final.minY, initial.minY, accuracy: 1)
        let audio = try XCTUnwrap(nativeView("dictation-audio-bars", in: hud))
        let thinking = try XCTUnwrap(nativeView("dictation-thinking", in: hud))
        let audioHeight = audio.frame.height
        hud.showThinking()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(audio.isHidden)
        XCTAssertFalse(thinking.isHidden)
        XCTAssertGreaterThan(audio.alphaValue, 0)
        XCTAssertLessThan(audio.alphaValue, 1)
        XCTAssertGreaterThan(thinking.alphaValue, 0)
        XCTAssertLessThan(thinking.alphaValue, 1)
        XCTAssertLessThan(audio.frame.height, audioHeight, "The audio bars should gather into the waiting track")
        try await assertThinking(hud)
        let track = try XCTUnwrap(nativeView("dictation-thinking-progress", in: hud))
        XCTAssertTrue(track.layer?.sublayers?.first?.animationKeys()?.contains("thinking-flow") == true)
        hud.show("续录的新文字", listening: true)
        try await Task.sleep(for: .milliseconds(60))
        hud.showThinking()
        try await Task.sleep(for: .milliseconds(60))
        hud.hide()
        hud.show("取消后立即重录", listening: true)
        try await Task.sleep(for: .milliseconds(360))
        try await assertWave(hud)
        XCTAssertNil(track.layer?.sublayers?.first?.animationKeys(), "Cancelled waiting effects must stop")
        let preview = try XCTUnwrap(nativeView("dictation-preview-text", in: hud) as? NSTextView)
        XCTAssertEqual(preview.string, "取消后立即重录")
    }

    func testSingleChannelSendWaitsForPolishedFinalAndFailureNeverSends() async throws {
        _ = NSApplication.shared
        for fails in [false, true] {
            let suite = "OpenVoice-PreviewSend-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set("wetype", forKey: "channel")
            defaults.set(true, forKey: "streaming")
            let hardware = ParityCapture(), engine = ParityEngine(), hud = HUD()
            var inserted: [(String, Bool)] = []
            let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
                enginePool: DictationEnginePool { _ in engine }, hud: hud, defaults: defaults,
                insertText: { inserted.append(($0, $1)) })
            defer {
                app.dictation.cancel(); hardware.close(); engine.close(); hud.hide()
                defaults.removePersistentDomain(forName: suite)
            }
            app.begin(sendOnFinish: true)
            try await parityEventually { engine.rounds.count == 1 }
            engine.rounds[0].partial("临时文字保留完整尾字")
            try await parityEventually { app.dictation.text == "临时文字保留完整尾字" }
            XCTAssertTrue(inserted.isEmpty)
            app.end()
            try await assertThinking(hud)
            XCTAssertTrue(inserted.isEmpty)
            engine.rounds[0].resolve(fails ? .failure(ASRError("受控网络错误")) : .success("润色定稿 𠮷 😀，保留完整尾字。"))
            try await parityEventually { inserted.count == 1 }
            XCTAssertEqual(inserted[0].0, fails ? "临时文字保留完整尾字" : "润色定稿 𠮷 😀，保留完整尾字。")
            XCTAssertEqual(inserted[0].1, !fails)
            XCTAssertFalse(app.dictation.isActive)
            if fails {
                let message = try await render(hud)
                XCTAssertTrue(message.text.contains { $0.contains("已保留已识别的文字") })
            } else { try await assertHidden(hud) }
        }
    }

    func testImmediateHUDHideCannotLaterHideResumedRecording() async throws {
        _ = NSApplication.shared
        let hud = HUD(reduceMotion: { false })
        defer { hud.hide() }
        hud.show("上一段", listening: true)
        XCTAssertTrue(hud.isVisible)
        hud.hide()
        XCTAssertTrue(hud.isVisible, "Retain the content while shrinking")
        hud.show("继续说", listening: true)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(hud.isVisible)
    }

    func testEmptyFinalUsesPreviewOnlySemanticsRegardlessOfLegacyPreference() async throws {
        _ = NSApplication.shared
        for streaming in [true, false] {
            let suite = "OpenVoice-EmptyHUD-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set("wetype", forKey: "channel")
            defaults.set(streaming, forKey: "streaming")
            let hardware = ParityCapture(), engine = ParityEngine(), hud = HUD()
            var pasted: [String] = []
            let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
                enginePool: DictationEnginePool { _ in engine }, hud: hud, defaults: defaults,
                insertText: { text, _ in pasted.append(text) })
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
            XCTAssertTrue(hud.isVisible)
            let image = try await render(hud)
            XCTAssertEqual(image.text, ["没有识别到内容"])
            XCTAssertFalse(image.processing)
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
            XCTAssertFalse(app.dictation.isActive)
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
            try await assertHidden(hud)
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
            XCTAssertFalse(message.processing)
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
