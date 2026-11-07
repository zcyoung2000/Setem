import Foundation
import XCTest
@testable import OpenVoice

@MainActor
final class DictationCaptureTests: XCTestCase {
    func testSourceEndingBeforeTakePreservesPrerollAndFinishesExactTranscript() async throws {
        let hardware = ParityCapture()
        defer { hardware.close() }
        let capture = DictationCapture(start: hardware.start, stop: hardware.stop)
        try capture.arm()
        hardware.send(101)
        hardware.send(102)
        try await parityEventually { hardware.sources[0].requests == 3 }
        hardware.sources[0].finish()
        // Let the source finish while the hotkey is still deciding tap/hold.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
        let stream = try capture.take()
        var text = "", finished = false
        let reader = Task { @MainActor in
            for await frame in stream { text += frame[0] == 101 ? "开头" : "和结尾。" }
            finished = true
        }
        defer { reader.cancel(); capture.stop() }
        try await parityEventually { finished }
        XCTAssertEqual(text, "开头和结尾。")
    }

    func testPrerollTransfersBoundedFramesAndTail() async throws {
        let hardware = ParityCapture()
        defer { hardware.close() }
        let capture = DictationCapture(start: hardware.start, stop: hardware.stop)
        try capture.arm()
        try capture.arm()
        XCTAssertEqual(hardware.sources.count, 1)
        for value in 1...60 { hardware.send(Int16(value)) }
        // Next requested frame proves all sixty have passed through the gate.
        try await parityEventually { hardware.sources[0].requests == 61 }
        let stream = try capture.take()
        XCTAssertFalse(capture.isPrimed)
        hardware.send(61)
        hardware.tail = 62
        capture.stop()
        var result: [Int16] = []
        for await frame in stream { result.append(frame[0]); XCTAssertEqual(frame.count, 320) }
        XCTAssertEqual(result, (11...62).map(Int16.init))
        XCTAssertEqual(hardware.stops, 1)
    }

    func testDiscardedPrerollCannotLeakIntoNextRecording() async throws {
        let hardware = ParityCapture()
        defer { hardware.close() }
        let capture = DictationCapture(start: hardware.start, stop: hardware.stop)
        try capture.arm()
        hardware.send(111)
        try await parityEventually { hardware.sources[0].requests == 2 }
        capture.disarm()
        capture.disarm()
        XCTAssertFalse(capture.isPrimed)
        let stream = try capture.take()
        hardware.send(222)
        capture.stop()
        var result: [Int16] = []
        for await frame in stream { result.append(frame[0]) }
        XCTAssertEqual(result, [222])
        XCTAssertEqual(hardware.stops, 2)
    }

    func testOldCaptureDrainCannotFinishNextRecording() async throws {
        let hardware = ParityCapture()
        hardware.finishesOnStop = false
        defer { hardware.close() }
        let capture = DictationCapture(start: hardware.start, stop: hardware.stop)
        let first = try capture.take()
        hardware.send(101)
        capture.stop()
        let second = try capture.take()
        hardware.send(201)
        // A vendor/hardware tail arrives after the next recording has opened.
        hardware.sources[0].send(102)
        hardware.sources[0].finish()
        var old: [Int16] = []
        for await frame in first { old.append(frame[0]) }
        XCTAssertEqual(old, [101, 102])
        hardware.send(202)
        capture.stop()
        hardware.sources[1].finish()
        var new: [Int16] = []
        for await frame in second { new.append(frame[0]) }
        XCTAssertEqual(new, [201, 202])
        XCTAssertEqual(hardware.stops, 2)
    }

    func testTranscriptMatchesUpstreamJoinAndEmptyFinalRules() {
        for streaming in [false, true] {
            var transcript = DictationTranscript()
            let a = transcript.begin(), b = transcript.begin(), c = transcript.begin()
            XCTAssertEqual(transcript.update(a, text: "Open"), true)
            XCTAssertEqual(transcript.update(a, text: "Open"), false)
            XCTAssertEqual(transcript.update(b, text: "Voice"), true)
            XCTAssertEqual(transcript.update(c, text: "尾字"), true)
            transcript.finish(b, text: "Voice", error: nil, keepPartial: streaming)
            transcript.finish(a, text: "Open", error: nil, keepPartial: streaming)
            XCTAssertFalse(transcript.finished)
            transcript.finish(c, text: "", error: nil, keepPartial: streaming)
            XCTAssertEqual(transcript.text, streaming ? "OpenVoice尾字" : "OpenVoice")
            XCTAssertTrue(transcript.finished)
            XCTAssertNil(transcript.update(b, text: "迟到"))
            XCTAssertFalse(transcript.finish(b, text: "迟到", error: "迟到错误", keepPartial: false))
            let d = transcript.begin()
            XCTAssertEqual(transcript.update(d, text: "保留"), true)
            transcript.finish(d, text: "", error: "首个错误", keepPartial: streaming)
            let e = transcript.begin()
            transcript.finish(e, text: "", error: "最近错误", keepPartial: streaming)
            XCTAssertEqual(transcript.text, streaming ? "OpenVoice尾字保留" : "OpenVoice保留")
            XCTAssertEqual(transcript.error, "最近错误")
        }
    }
}
