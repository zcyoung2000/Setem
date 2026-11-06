import Foundation
import XCTest
@testable import OpenVoice

@MainActor
final class DictationEnginePoolTests: XCTestCase {
    func testPoolWaitsForWarmupAndNeverSharesBusyEngine() async throws {
        let hardware = ParityCapture()
        var engines: [ParityEngine] = []
        let pool = DictationEnginePool { _ in
            let engine = ParityEngine()
            engine.blocksPreparation = engines.isEmpty
            engines.append(engine)
            return engine
        }
        var results: [DictationSession.Result] = []
        let model = DictationSession(startCapture: hardware.start, stopCapture: hardware.stop, enginePool: pool)
        model.onFinish = { results.append($0) }
        defer { model.cancel(); hardware.close(); engines.forEach { $0.close() } }
        pool.prewarm(.wetype)
        try await parityEventually { engines[0].preparing }
        try model.start(channel: .wetype)
        let concurrent = pool.take(.wetype)
        XCTAssertFalse(concurrent.engine === engines[0])
        XCTAssertTrue(engines[0].rounds.isEmpty)
        hardware.send(333)
        model.end()
        engines[0].prepared()
        try await parityEventually { engines[0].rounds.count == 1 && engines[0].rounds[0].ended }
        XCTAssertEqual(engines[0].rounds[0].samples, [333])
        engines[0].rounds[0].resolve(.success("预热握手期间的首音没有丢。"))
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results[0].text, "预热握手期间的首音没有丢。")
        let reused = pool.take(.wetype)
        XCTAssertTrue(reused.engine === engines[0])
    }

    func testPoolReusesSuccessButDiscardsFailure() async throws {
        let hardware = ParityCapture()
        var engines: [ParityEngine] = []
        let pool = DictationEnginePool { _ in let e = ParityEngine(); engines.append(e); return e }
        var results: [DictationSession.Result] = []
        let model = DictationSession(startCapture: hardware.start, stopCapture: hardware.stop, enginePool: pool)
        model.onFinish = { results.append($0) }
        defer { model.cancel(); hardware.close(); engines.forEach { $0.close() } }
        try model.start(channel: .qwen)
        try await parityEventually { engines[0].rounds.count == 1 }
        engines[0].rounds[0].resolve(.success("第一次完整定稿。"))
        try await parityEventually { results.count == 1 }
        try model.start(channel: .qwen)
        try await parityEventually { engines[0].rounds.count == 2 }
        XCTAssertEqual(engines.count, 1)
        engines[0].rounds[1].resolve(.failure(ASRError("连接损坏")))
        try await parityEventually { results.count == 2 }
        XCTAssertEqual(results[1].error, "连接损坏")
        try model.start(channel: .qwen)
        try await parityEventually { engines.count == 2 && engines[1].rounds.count == 1 }
        XCTAssertFalse(engines[0] === engines[1])
        model.cancel()
        try model.start(channel: .qwen)
        try await parityEventually { engines.count == 3 && engines[2].rounds.count == 1 }
        engines[1].rounds[0].resolve(.success("取消后的迟到成功"))
        try await parityEventually { engines[1].rounds[0].returned }
        let next = pool.take(.qwen)
        XCTAssertFalse(next.engine === engines[1])
        XCTAssertFalse(next.engine === engines[2])
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(results.count, 2)
    }

    func testSingleSessionPinsChannelAndUsesVerbatimJoin() async throws {
        let hardware = ParityCapture()
        var engines: [ParityEngine] = []
        var result: DictationSession.Result?
        let model = DictationSession(startCapture: hardware.start, stopCapture: hardware.stop, makeEngine: { _ in
            let e = ParityEngine(); engines.append(e); return e
        })
        model.onFinish = { result = $0 }
        defer { model.cancel(); hardware.close(); engines.forEach { $0.close() } }
        try model.start(channel: .doubao)
        model.end()
        try model.start(channel: .wetype)
        XCTAssertEqual(model.channel, .doubao)
        try await parityEventually { engines.allSatisfy { $0.rounds.count == 1 } }
        engines[1].rounds[0].partial("Voice尾字")
        try await parityEventually { model.text == "Voice尾字" }
        engines[0].rounds[0].resolve(.success("Open"))
        try await parityEventually { model.text == "OpenVoice尾字" }
        model.end()
        engines[1].rounds[0].resolve(.success(""))
        try await parityEventually { result != nil }
        XCTAssertEqual(result?.text, "Open")
    }

    func testEarlyCurrentFinalWaitsForOlderSegmentBeforeStoppingCapture() async throws {
        let hardware = ParityCapture()
        var engines: [ParityEngine] = []
        var result: DictationSession.Result?
        let model = DictationSession(startCapture: hardware.start, stopCapture: hardware.stop, makeEngine: { _ in
            let e = ParityEngine(); engines.append(e); return e
        })
        model.onFinish = { result = $0 }
        defer { model.cancel(); hardware.close(); engines.forEach { $0.close() } }
        try model.start(channel: .doubao)
        model.end()
        try model.start(channel: .doubao)
        try await parityEventually { engines.allSatisfy { $0.rounds.count == 1 } }
        engines[1].rounds[0].resolve(.success("后说的。"))
        try await parityEventually { model.text == "后说的。" }
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(hardware.stops, 1)
        engines[0].rounds[0].resolve(.success("先说的。"))
        try await parityEventually { result != nil }
        XCTAssertEqual(result?.text, "先说的。后说的。")
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(hardware.stops, 2)
    }
}
