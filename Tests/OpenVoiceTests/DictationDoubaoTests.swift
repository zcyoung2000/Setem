import XCTest
@testable import OpenVoice

final class DictationDoubaoTests: XCTestCase {
    // D1: a cumulative update can contain new speech after an indexed final.
    func testCumulativeTailRemainsVisibleAfterIndexedFinal() {
        var shown: [String] = []
        let transcript = DoubaoEngine.Transcript { shown.append($0) }

        transcript.update(#"{"results":[{"index":0,"text":"明天四点开会，通知张经理。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"text":"明天四点开会，通知张经理。请带上完整测试报告"}]}"#)

        XCTAssertEqual(transcript.result, "明天四点开会，通知张经理。请带上完整测试报告")
        XCTAssertEqual(shown, ["明天四点开会，通知张经理。", "明天四点开会，通知张经理。请带上完整测试报告"])
    }

    func testCumulativeResultRemainsAuthoritativeWithoutIndexedSentences() {
        var shown: [String] = []
        let transcript = DoubaoEngine.Transcript { shown.append($0) }

        transcript.update(#"{"results":[{"text":"第一句。"}]}"#)
        transcript.update(#"{"results":[{"text":"第一句。第二句。"}]}"#)

        XCTAssertEqual(transcript.result, "第一句。第二句。")
        XCTAssertEqual(shown, ["第一句。", "第一句。第二句。"])
    }

    func testIndexedPolishedFinalsSurviveLateCumulativeResponses() {
        var shown: [String] = []
        let transcript = DoubaoEngine.Transcript { shown.append($0) }

        transcript.update(#"{"results":[{"text":"第一句原始稿。第二句原始稿"}]}"#)
        transcript.update(#"{"results":[{"index":0,"text":"第一句润色稿。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"text":"第一句原始稿。第二句原始稿"}]}"#)
        transcript.update(#"{"results":[{"index":1,"text":"第二句润色稿。","extra":{"nonstream_result":true}}]}"#)

        XCTAssertEqual(transcript.result, "第一句润色稿。第二句润色稿。")
        XCTAssertEqual(shown, [
            "第一句原始稿。第二句原始稿",
            "第一句润色稿。第二句原始稿",
            "第一句润色稿。第二句原始稿",
            "第一句润色稿。第二句润色稿。",
        ])
    }

    // D2: both existing final flags apply to cumulative, as well as indexed, results.
    func testCumulativeFinalSupersedesIndexedTextAndRejectsLatePartials() {
        for finalFlags in [#""extra":{"nonstream_result":true}"#, #""is_interim":false,"is_vad_finished":true"#] {
            var shown: [String] = []
            let transcript = DoubaoEngine.Transcript { shown.append($0) }
            transcript.update(#"{"results":[{"index":0,"text":"第一句。","extra":{"nonstream_result":true}}]}"#)
            transcript.update("{\"results\":[{\"text\":\"整段润色后的第一句。第二句润色稿。\",\(finalFlags)}]}")
            XCTAssertEqual(transcript.result, "整段润色后的第一句。第二句润色稿。")

            let count = shown.count
            transcript.update(#"{"results":[{"text":"第一句原始稿。第二句原始稿"}]}"#)
            transcript.update(#"{"results":[{"index":1,"text":"第二句原始稿","is_interim":true}]}"#)
            XCTAssertEqual(transcript.result, "整段润色后的第一句。第二句润色稿。")
            XCTAssertEqual(shown.last, "整段润色后的第一句。第二句润色稿。")
            XCTAssertEqual(shown.count, count)
        }
    }

    // D2: a complete final may itself be corrected, without concatenating two versions.
    func testCumulativeFinalCanBeRevised() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"text":"明天三点开会。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"text":"明天下午三点开会。","extra":{"nonstream_result":true}}]}"#)
        XCTAssertEqual(transcript.result, "明天下午三点开会。")
    }

    // D1/D2: a finalized cumulative prefix does not mean the recording has ended.
    func testCumulativePrefixFinalDoesNotBlockLaterSpeech() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"text":"第一句原始稿。"}]}"#)
        transcript.update(#"{"results":[{"text":"第一句润色稿。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"text":"第一句原始稿。第二句原始稿"}]}"#)
        XCTAssertEqual(transcript.result, "第一句润色稿。第二句原始稿")
        transcript.update(#"{"results":[{"index":1,"text":"第二句润色稿。","extra":{"nonstream_result":true}}]}"#)
        XCTAssertEqual(transcript.result, "第一句润色稿。第二句润色稿。")
    }

    // D3: retain the observed raw sentence as its identity, even after a large rewrite.
    func testPolishingLengthChangesDoNotCutOrDuplicateCumulativeTail() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"index":0,"text":"嗯这个就是明天开会","is_interim":true}]}"#)
        transcript.update(#"{"results":[{"text":"嗯这个就是明天开会。请带报告"}]}"#)
        transcript.update(#"{"results":[{"index":0,"text":"明天开会。","extra":{"nonstream_result":true}}]}"#)
        XCTAssertEqual(transcript.result, "明天开会。请带报告")

        transcript.update(#"{"results":[{"text":"嗯这个就是明天开会。请带完整报告和附件"}]}"#)
        XCTAssertEqual(transcript.result, "明天开会。请带完整报告和附件")
        transcript.update(#"{"results":[{"index":1,"text":"请携带完整报告及附件。","extra":{"nonstream_result":true}}]}"#)
        XCTAssertEqual(transcript.result, "明天开会。请携带完整报告及附件。")
    }

    // D4: updating an older index must not clear the current newer sentence.
    func testOlderFinalCannotDiscardNewerIndexedPartial() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"index":0,"text":"第一句原稿。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"index":1,"text":"第二句还在说","is_interim":true}]}"#)
        transcript.update(#"{"results":[{"index":0,"text":"第一句润色稿。","extra":{"nonstream_result":true}}]}"#)
        XCTAssertEqual(transcript.result, "第一句润色稿。第二句还在说")
    }

    // D4: completion order must not change spoken order.
    func testOutOfOrderIndexedFinalsStayInSentenceOrder() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"index":1,"text":"第二句。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"index":0,"text":"第一句。","extra":{"nonstream_result":true}}]}"#)
        XCTAssertEqual(transcript.result, "第一句。第二句。")
    }

    // D4: only another final can replace a finalized sentence.
    func testIndexedRevisionRejectsLatePartialForSameSentence() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"index":0,"text":"明天开会。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"index":0,"text":"明天下午开会。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"index":0,"text":"明天开","is_interim":true}]}"#)
        XCTAssertEqual(transcript.result, "明天下午开会。")
    }

    // D1/D2: malformed/empty input and auxiliary candidates do not become the transcript.
    func testEmptyResponsesAndAuxiliaryCandidatesCannotReplaceTranscript() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"text":"完整文字。"},{"text":"辅助候选。"}]}"#)
        for response in ["not json", #"{"results":[]}"#, #"{"results":[{"text":""}]}"#] {
            transcript.update(response)
            XCTAssertEqual(transcript.result, "完整文字。")
        }
    }

    // D2: SessionFinished can be the only final marker on the full transcript.
    func testSessionFinishedCumulativeTextIsFinal() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"index":0,"text":"第一句。","extra":{"nonstream_result":true}}]}"#)
        transcript.update(#"{"results":[{"text":"第一句。完整第二句。"}]}"#, sessionFinished: true)
        transcript.update(#"{"results":[{"text":"第一句原稿"}]}"#)
        XCTAssertEqual(transcript.result, "第一句。完整第二句。")
    }

    // D3: the last indexed interim can be shorter than its source in the cumulative text.
    func testFinalOutgrowingIndexedPartialConsumesWholeSourceSentence() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"index":0,"text":"今天去","is_interim":true}]}"#)
        transcript.update(#"{"results":[{"text":"今天去上海出差。请带报告"}]}"#)
        transcript.update(#"{"results":[{"index":0,"text":"今天要去上海出差。","extra":{"nonstream_result":true}}]}"#)
        XCTAssertEqual(transcript.result, "今天要去上海出差。请带报告")
    }

    // D3: raw pieces are adjacent substrings, rather than independent sentences to space-join.
    func testCumulativeOverlayPreservesWhitespaceAndUnicode() {
        let transcript = DoubaoEngine.Transcript { _ in }
        transcript.update(#"{"results":[{"index":0,"text":"hello world","is_interim":true}]}"#)
        transcript.update(#"{"results":[{"text":"hello world.\nNext: 👨‍👩‍👧‍👦 𠮷"}]}"#)
        transcript.update(#"{"results":[{"index":0,"text":"Hello, world!","extra":{"nonstream_result":true}}]}"#)
        XCTAssertEqual(transcript.result, "Hello, world!\nNext: 👨‍👩‍👧‍👦 𠮷")
    }

    // D1: exercise the production session callbacks, not just the parser's result getter.
    @MainActor
    func testSessionKeepsCumulativeTailOnSuccessAndFailure() async throws {
        for fails in [false, true] {
            let engine = DoubaoReplayEngine()
            let capture = ParityCapture()
            let model = DictationSession(startCapture: { try capture.start() }, stopCapture: { capture.stop() },
                                         makeEngine: { _ in engine })
            defer { model.cancel(); capture.close(); engine.responses.finish() }
            var results: [DictationSession.Result] = []
            var previews: [String] = []
            model.onFinish = { results.append($0) }
            model.onUpdate = { previews.append($0) }
            try model.start(channel: .doubao)
            try await parityEventually { engine.started }
            engine.responses.yield(#"{"results":[{"index":0,"text":"第一句。","extra":{"nonstream_result":true}}]}"#)
            try await parityEventually { model.text == "第一句。" }
            engine.responses.yield(#"{"results":[{"text":"第一句。第二句尾字。"}]}"#)
            try await parityEventually { model.text == "第一句。第二句尾字。" }
            XCTAssertEqual(previews.last, "第一句。第二句尾字。")
            model.end()
            engine.responses.finish(throwing: fails ? ASRError("controlled disconnect") : nil)
            try await parityEventually { results.count == 1 }
            XCTAssertEqual(results[0].text, "第一句。第二句尾字。")
            XCTAssertEqual(results[0].error, fails ? "controlled disconnect" : nil)
            XCTAssertEqual(capture.stops, 1)
        }
    }
}

@MainActor
private final class DoubaoReplayEngine: ASREngine {
    private let stream: AsyncThrowingStream<String, Error>
    let responses: AsyncThrowingStream<String, Error>.Continuation
    private(set) var started = false

    init() {
        (stream, responses) = AsyncThrowingStream<String, Error>.makeStream()
    }

    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        let transcript = DoubaoEngine.Transcript(partial: partial)
        started = true
        for try await response in stream { transcript.update(response) }
        return transcript.result
    }
}
