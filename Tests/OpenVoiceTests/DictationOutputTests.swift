import AppKit
import XCTest
@testable import OpenVoice

@MainActor
final class DictationOutputTests: XCTestCase {
    func testPreferenceDefaultsOffAndRemovesOnlyOneFinalPunctuation() throws {
        let suite = "OpenVoice-OutputFormatting-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DictationOutput.textForInsertion("你好，世界！！", defaults: defaults), "你好，世界！！")
        defaults.set(true, forKey: DictationOutput.removeTrailingPunctuationKey)
        let cases = [
            ("你好，世界。", "你好，世界"), ("Hello?!", "Hello?"), ("等等……", "等等…"),
            ("你好，世界！！", "你好，世界！"), ("句中，标点；保留", "句中，标点；保留"),
            ("结尾。 \r\n", "结尾 \r\n"), ("e\u{301} 𠮷 😀。", "e\u{301} 𠮷 😀"),
            ("版本 3.14", "版本 3.14"), ("C++", "C++"), ("你好 😀", "你好 😀"),
            ("。 \n", ""), ("！", ""), ("", ""), (" \n", " \n")
        ]
        for (input, expected) in cases {
            let output = DictationOutput.textForInsertion(input, defaults: defaults)
            XCTAssertEqual(Array(output.utf16), Array(expected.utf16), "Input: \(input.debugDescription)")
        }
        defaults.set(false, forKey: DictationOutput.removeTrailingPunctuationKey)
        XCTAssertEqual(DictationOutput.textForInsertion("你好。", defaults: defaults), "你好。")
    }

    func testEveryChannelFormatsOnlyTheFinalInsertionAndPreservesSendBehavior() async throws {
        for channel in Channel.engines {
            for enabled in [false, true] {
                for sendsReturn in [false, true] {
                    let suite = "OpenVoice-OutputFinal-" + UUID().uuidString
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                    defaults.set(channel.rawValue, forKey: "channel")
                    let hardware = ParityCapture(), engine = ParityEngine()
                    let hud = HUD(reduceMotion: { true })
                    var inserted: [(String, Bool)] = []
                    let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
                        enginePool: DictationEnginePool { _ in engine }, hud: hud, defaults: defaults,
                        failoverPolicy: nil, insertText: { inserted.append(($0, $1)) })
                    defer {
                        app.dictation.cancel(); hardware.close(); engine.close(); hud.hide()
                        defaults.removePersistentDomain(forName: suite)
                    }
                    app.begin(sendOnFinish: sendsReturn)
                    try await parityEventually { engine.rounds.count == 1 }
                    engine.rounds[0].partial("临时预览，保留标点。")
                    try await parityEventually { app.dictation.text == "临时预览，保留标点。" }
                    XCTAssertTrue(inserted.isEmpty)
                    app.end()
                    // Changes made while finalizing apply to the upcoming insertion.
                    defaults.set(enabled, forKey: DictationOutput.removeTrailingPunctuationKey)
                    let final = "完整稿，𠮷 😀 e\u{301}，保留尾字！！"
                    engine.rounds[0].resolve(.success(final))
                    try await parityEventually { !app.dictation.isActive }
                    XCTAssertEqual(inserted.count, 1)
                    XCTAssertEqual(inserted.first?.0, enabled ? "完整稿，𠮷 😀 e\u{301}，保留尾字！" : final)
                    XCTAssertEqual(inserted.first?.1, sendsReturn)
                    XCTAssertEqual(app.dictation.text, final, "Formatting must not rewrite recognition or preview text")
                }
            }
        }
    }

    func testPunctuationOnlyFinalCannotInsertOrSendAnEmptyMessage() async throws {
        let suite = "OpenVoice-OutputEmpty-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: DictationOutput.removeTrailingPunctuationKey)
        let hardware = ParityCapture(), engine = ParityEngine(), hud = HUD(reduceMotion: { true })
        var insertions = 0
        let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
            enginePool: DictationEnginePool { _ in engine }, hud: hud, defaults: defaults,
            failoverPolicy: nil, insertText: { _, _ in insertions += 1 })
        defer {
            app.dictation.cancel(); hardware.close(); engine.close(); hud.hide()
            defaults.removePersistentDomain(forName: suite)
        }
        app.begin(sendOnFinish: true)
        try await parityEventually { engine.rounds.count == 1 }
        app.end()
        engine.rounds[0].resolve(.success("。 \n"))
        try await parityEventually { !app.dictation.isActive }
        XCTAssertEqual(insertions, 0)
    }

    func testErrorAndTimeoutPreservedTextUseTheSameOutputPreference() async throws {
        for timeout in [false, true] {
            let suite = "OpenVoice-OutputError-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: DictationOutput.removeTrailingPunctuationKey)
            let hardware = ParityCapture(), engine = ParityEngine(), hud = HUD(reduceMotion: { true })
            var inserted: [(String, Bool)] = []
            let app = AppDelegate(capture: DictationCapture(start: hardware.start, stop: hardware.stop),
                enginePool: DictationEnginePool { _ in engine }, hud: hud, defaults: defaults,
                failoverPolicy: nil, insertText: { inserted.append(($0, $1)) })
            defer {
                app.dictation.cancel(); hardware.close(); engine.close(); hud.hide()
                defaults.removePersistentDomain(forName: suite)
            }
            app.begin(sendOnFinish: true)
            try await parityEventually { engine.rounds.count == 1 }
            engine.rounds[0].partial("保留已识别的文字。")
            try await parityEventually { app.dictation.text == "保留已识别的文字。" }
            if timeout { app.dictation.cancel("受控超时") }
            else {
                app.end()
                engine.rounds[0].resolve(.failure(ASRError("受控网络错误")))
            }
            try await parityEventually { !app.dictation.isActive }
            XCTAssertEqual(inserted.count, 1)
            XCTAssertEqual(inserted.first?.0, "保留已识别的文字")
            XCTAssertEqual(inserted.first?.1, false)
        }
    }
}
