import Foundation
import XCTest
@testable import OpenVoice

@MainActor
final class DictationCaptureTests: XCTestCase {
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

    func testQuietSpeechExtendsActivityButRepeatedTextDoesNot() async throws {
        var now: TimeInterval = 0
        let activity = DictationActivity(now: { now })
        let hardware = ParityCapture()
        var engines: [ParityEngine] = []
        let model = DictationSession(startCapture: hardware.start, stopCapture: hardware.stop, makeEngine: { _ in
            let engine = ParityEngine(); engines.append(engine); return engine
        })
        var updates = 0
        model.onCaptureChanged = { $0 ? activity.start() : activity.stop() }
        model.onSpeech = { activity.speaking() }
        model.onUpdate = { _ in updates += 1 }
        defer { model.cancel(); hardware.close(); engines.forEach { $0.close() } }
        try model.start(channel: .wetype)
        try await parityEventually { engines[0].rounds.count == 1 }
        now = 7.9
        engines[0].rounds[0].partial("小声说的尾字")
        try await parityEventually { updates == 1 }
        now = 8.9
        XCTAssertFalse(activity.shouldStop(level: 0.01, silence: 1.5))
        engines[0].rounds[0].partial("小声说的尾字")
        // Drain the same main-queue FIFO used by partial callbacks. Identical
        // text now intentionally skips UI updates, but must still not count as speech.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        XCTAssertEqual(updates, 1)
        now = 9.5
        XCTAssertTrue(activity.shouldStop(level: 0.01, silence: 1.5))
        model.end()
        try model.start(channel: .wetype)
        try await parityEventually { engines[1].rounds.count == 1 }
        now = 16.5
        engines[0].rounds[0].resolve(.success("上一段润色定稿。"))
        try await parityEventually { model.text == "上一段润色定稿。" }
        now = 17.6
        // A late final is not new speech in the current recording.
        XCTAssertTrue(activity.shouldStop(level: 0, silence: 1.5))
        XCTAssertTrue(model.isRecording)
    }

    func testSilenceCanBeDisabledAndInitialSilenceExpires() {
        var now: TimeInterval = 0
        let activity = DictationActivity(now: { now })
        activity.start()
        now = 8
        XCTAssertFalse(activity.shouldStop(level: 0, silence: 1.5))
        now = 8.01
        XCTAssertTrue(activity.shouldStop(level: 0, silence: 1.5))
        XCTAssertFalse(activity.shouldStop(level: 0, silence: 1.5, enabled: false))
        XCTAssertFalse(activity.shouldStop(level: 0.31, silence: 1.5))
        now = 9.6
        XCTAssertTrue(activity.shouldStop(level: 0.3, silence: 1.5))
        activity.stop()
        XCTAssertFalse(activity.shouldStop(level: 0, silence: 1.5))
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
