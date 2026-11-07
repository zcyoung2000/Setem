import Foundation
import XCTest
@testable import OpenVoice

/// Deliberately does not finish when cancelled: real network callbacks may arrive much later.
@MainActor
private final class DictationTestEngine: ASREngine {
    private var reply: CheckedContinuation<String, Error>?
    private var partial: ((String) -> Void)?
    private(set) var started = false
    private(set) var returned = false
    private(set) var audioEnded = false
    private(set) var samples: [Int16] = []
    var immediateReply: Swift.Result<String, Error>?

    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        self.partial = partial
        started = true
        let reader = Task {
            for await frame in audio { samples.append(frame[0]) }
            audioEnded = true
        }
        defer { reader.cancel(); returned = true }
        if let immediateReply {
            partial("同步回调的完整尾字")
            return try immediateReply.get()
        }
        return try await withCheckedThrowingContinuation { reply = $0 }
    }

    func emit(_ text: String) { partial?(text) }
    func resolve(_ result: Swift.Result<String, Error>) {
        let pending = reply
        reply = nil
        pending?.resume(with: result)
    }
}

@MainActor
private final class DictationTestCapture {
    private var current: AsyncStream<[Int16]>.Continuation?
    private(set) var starts = 0
    private(set) var stops = 0
    var startError: Error?
    func start() throws -> AsyncStream<[Int16]> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        current = continuation
        starts += 1
        return stream
    }
    func send(_ marker: Int16) { current?.yield([Int16](repeating: marker, count: 320)) }
    func stop() { stops += 1; current?.finish(); current = nil }
}

/// Advances explicitly, even if the caller cancelled its sleep; exercises timeout ownership.
@MainActor
private final class DictationTestClock {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private(set) var wakes = 0
    var pending: Int { waiters.count }
    func sleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
        wakes += 1
    }
    func advanceNext() { waiters.removeFirst().resume() }
    func advance() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class DictationRig {
    let capture = DictationTestCapture()
    let clock = DictationTestClock()
    var engines: [DictationTestEngine] = []
    var channels: [Channel] = []
    var updates: [String] = []
    var results: [DictationSession.Result] = []
    var cancellations: [(text: String, message: String?)] = []
    var configure: (DictationTestEngine) -> Void = { _ in }
    var captureFailure: () -> (() -> String?) = { { nil } }
    lazy var model: DictationSession = {
        let model = DictationSession(startCapture: { [unowned self] in try capture.start() },
                                     stopCapture: { [unowned self] in capture.stop() },
                                     captureFailure: { [unowned self] in captureFailure() },
                                     makeEngine: { [unowned self] channel in
            let engine = DictationTestEngine()
            configure(engine)
            channels.append(channel)
            engines.append(engine)
            return engine
        }, sleep: { [unowned self] seconds in try await clock.sleep(seconds) })
        model.onUpdate = { [unowned self] in updates.append($0) }
        model.onFinish = { [unowned self] in results.append($0) }
        model.onCancel = { [unowned self] in cancellations.append(($0, $1)) }
        return model
    }()
    func close() {
        model.cancel()
        engines.forEach { $0.resolve(.failure(CancellationError())) }
        clock.advance()
    }
}

/// Traceability and exact oracles: docs/dictation-baseline.md (R1–R4).
@MainActor
final class DictationSessionTests: XCTestCase {
    func testDeferredCaptureFailurePreservesThePendingExactFinal() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        var recording = 0
        rig.captureFailure = {
            recording += 1
            let own = recording
            return { own == 2 ? "回声抑制设备启动失败" : nil }
        }
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines[0].started }
        rig.model.end()
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines.count == 2 && rig.engines[1].started }
        rig.engines[1].resolve(.success(""))
        try await eventually { !rig.model.isRecording }
        XCTAssertTrue(rig.model.isActive)
        XCTAssertTrue(rig.results.isEmpty)
        XCTAssertTrue(rig.cancellations.isEmpty)
        rig.engines[0].resolve(.success("上一段完整润色稿，保留最后一个尾字。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0], .init(text: "上一段完整润色稿，保留最后一个尾字。",
                                            error: "回声抑制设备启动失败", sendsReturn: false))
    }

    func testOldDeferredCaptureFailureCannotStopTheNewRecording() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        var recording = 0
        rig.captureFailure = {
            recording += 1
            let own = recording
            return { own == 1 ? "旧录音设备启动失败" : nil }
        }
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines[0].started }
        rig.model.end()
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines.count == 2 && rig.engines[1].started }
        rig.engines[0].resolve(.success(""))
        try await eventually { rig.engines[0].returned }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(rig.model.isRecording)
        XCTAssertEqual(rig.capture.stops, 1)
        rig.capture.send(201)
        rig.model.end()
        rig.engines[1].resolve(.success("第二段完整润色稿，尾字。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0].text, "第二段完整润色稿，尾字。")
        XCTAssertEqual(rig.results[0].error, "旧录音设备启动失败")
        XCTAssertEqual(rig.capture.stops, 2)
    }

    func testRepeatedPartialsDoNotRefreshUIButEncodedRevisionsAndFinalAreDelivered() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines.first?.started == true }
        let first = "完整预览e\u{301}"
        let revised = "完整预览é"
        for _ in 0..<20 { rig.engines[0].emit(first) }
        rig.engines[0].emit(revised)
        rig.engines[0].emit("下一句")
        try await eventually { rig.updates.last == "下一句" }
        XCTAssertEqual(rig.updates.count, 3)
        XCTAssertTrue(rig.updates[0].utf16.elementsEqual(first.utf16))
        XCTAssertTrue(rig.updates[1].utf16.elementsEqual(revised.utf16))
        rig.model.end()
        rig.engines[0].resolve(.success("完整定稿，最后一个尾字。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0].text, "完整定稿，最后一个尾字。")
        XCTAssertEqual(rig.updates.last, "完整定稿，最后一个尾字。")
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Dictation did not reach expected state", file: file, line: line)
        throw ASRError("测试等待超时")
    }

    // R1/R3: a previous final must neither be lost nor stop the new recording.
    func testContinueWhileFinalizingKeepsPolishedTextAndRecording() async throws {
        for channel in [Channel.doubao, .wetype] {
            let rig = DictationRig()
            defer { rig.close() }
            try rig.model.start(channel: channel)
            try await eventually { rig.engines[0].started }
            rig.capture.send(101)
            rig.engines[0].emit("明天三点，不对，四点开会，通知张经")
            try await eventually { rig.model.text.hasSuffix("张经") }
            rig.model.end()
            try rig.model.start(channel: .qwen) // The in-progress dictation pins its original channel.
            try await eventually { rig.engines[1].started }
            rig.capture.send(202)
            rig.engines[0].resolve(.success("明天四点开会，通知张经理。"))
            try await eventually { rig.model.text == "明天四点开会，通知张经理。" }
            XCTAssertTrue(rig.model.isRecording)
            XCTAssertEqual(rig.capture.stops, 1)
            XCTAssertTrue(rig.results.isEmpty)
            XCTAssertEqual(rig.channels, [channel, channel])
            rig.capture.send(203)
            rig.model.end()
            try await eventually { rig.engines[1].audioEnded }
            rig.engines[1].resolve(.success("请带上完整测试报告。"))
            try await eventually { rig.results.count == 1 }
            XCTAssertEqual(rig.results[0], .init(text: "明天四点开会，通知张经理。请带上完整测试报告。", error: nil, sendsReturn: false))
            XCTAssertEqual(rig.engines[0].samples, [101])
            XCTAssertEqual(rig.engines[1].samples, [202, 203])
            XCTAssertEqual(rig.capture.stops, 2)
            XCTAssertFalse(rig.model.isActive)
            XCTAssertTrue(rig.cancellations.isEmpty)
        }
    }

    // R1/R3: service completion order must not reorder the user's speech.
    func testOutOfOrderFinalsRemainInRecordingOrder() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        for _ in 0..<3 { try rig.model.start(channel: .wetype); rig.model.end() }
        try await eventually { rig.engines.allSatisfy(\.started) }
        rig.engines[2].resolve(.success("第三段。"))
        rig.engines[1].resolve(.success("第二段。"))
        try await eventually { rig.engines[1].returned && rig.engines[2].returned }
        XCTAssertTrue(rig.results.isEmpty)
        rig.engines[0].resolve(.success("第一段。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0].text, "第一段。第二段。第三段。")
    }

    // R2/R3: a finalized segment is immutable, even while the session continues.
    func testLatePartialCannotOverwriteFinal() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        try rig.model.start(channel: .wetype)
        rig.model.end()
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines.allSatisfy(\.started) }
        rig.engines[0].resolve(.success("通知张经理。"))
        try await eventually { rig.model.text == "通知张经理。" }
        rig.engines[0].emit("通知张经")
        rig.model.end()
        rig.engines[1].resolve(.success("带好报告。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0].text, "通知张经理。带好报告。")
        XCTAssertFalse(rig.updates.contains("通知张经"))
    }

    // R2: cover all three old completion paths, not just cooperative task cancellation.
    func testOldCallbacksCannotStopOrOverwriteNewSession() async throws {
        let oldReplies: [Swift.Result<String, Error>] = [
            .success("旧会话定稿"), .failure(CancellationError()), .failure(ASRError("旧连接断开")),
        ]
        for oldReply in oldReplies {
            let rig = DictationRig()
            defer { rig.close() }
            try rig.model.start(channel: .wetype)
            try await eventually { rig.engines[0].started }
            rig.model.cancel()
            try rig.model.start(channel: .doubao)
            try await eventually { rig.engines[1].started }
            rig.engines[1].emit("新会话内容")
            try await eventually { rig.model.text == "新会话内容" }
            rig.engines[0].emit("旧会话临时文字")
            rig.engines[0].resolve(oldReply)
            try await eventually { rig.engines[0].returned }
            XCTAssertTrue(rig.model.isRecording)
            XCTAssertEqual(rig.capture.stops, 1)
            XCTAssertEqual(rig.model.text, "新会话内容")
            XCTAssertTrue(rig.results.isEmpty)
            XCTAssertEqual(rig.cancellations.count, 1)
            rig.capture.send(303)
            rig.model.end()
            try await eventually { rig.engines[1].audioEnded }
            rig.engines[1].resolve(.success("新会话完整尾字。"))
            try await eventually { rig.results.count == 1 }
            XCTAssertEqual(rig.results[0], .init(text: "新会话完整尾字。", error: nil, sendsReturn: false))
            XCTAssertEqual(rig.engines[1].samples, [303])
        }
    }

    // R1/R2/R4: an old timeout cannot abort resumed recording or a later waiting period.
    func testResumeInvalidatesOldTimeout() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        try rig.model.start(channel: .wetype)
        rig.model.end()
        try await eventually { rig.clock.pending == 1 }
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines.allSatisfy(\.started) }
        XCTAssertTrue(rig.model.isRecording)
        XCTAssertEqual(rig.capture.stops, 1)
        rig.model.end()
        try await eventually { rig.clock.pending == 2 }
        rig.clock.advanceNext()
        try await eventually { rig.clock.wakes == 1 }
        try await eventually { rig.clock.pending == 1 }
        XCTAssertTrue(rig.model.isActive)
        XCTAssertTrue(rig.cancellations.isEmpty)
        XCTAssertEqual(rig.capture.stops, 2)
        rig.engines[0].resolve(.success("上一段完整稿。"))
        rig.engines[1].resolve(.success("下一段完整稿。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0].text, "上一段完整稿。下一段完整稿。")
    }

    // R2/R4: timeout deliberately keeps recognized text, without committing a late final.
    func testTimeoutKeepsTextAndIgnoresLateFinal() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        try rig.model.start(channel: .doubao)
        try await eventually { rig.engines[0].started }
        rig.engines[0].emit("已识别的文字")
        try await eventually { rig.model.text == "已识别的文字" }
        rig.model.end()
        try await eventually { rig.clock.pending == 1 }
        rig.clock.advance()
        try await eventually { rig.cancellations.count == 1 }
        XCTAssertEqual(rig.cancellations[0].text, "已识别的文字")
        XCTAssertEqual(rig.cancellations[0].message, "识别超时")
        rig.engines[0].resolve(.success("迟到定稿"))
        try await eventually { rig.engines[0].returned }
        XCTAssertFalse(rig.model.isActive)
        XCTAssertTrue(rig.results.isEmpty)
        XCTAssertEqual(rig.capture.stops, 1)
    }

    // R2/R4: cancellation freezes output before the service acknowledges cancellation.
    func testExplicitCancelFreezesStreamImmediately() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines[0].started }
        rig.engines[0].emit("保留屏幕文字")
        try await eventually { rig.updates.last == "保留屏幕文字" }
        rig.model.cancel()
        rig.model.cancel()
        let before = rig.updates
        rig.engines[0].emit("取消后的临时文字")
        rig.engines[0].resolve(.success("取消后的最终文字"))
        try await eventually { rig.engines[0].returned }
        XCTAssertEqual(rig.updates, before)
        XCTAssertEqual(rig.cancellations.count, 1)
        XCTAssertNil(rig.cancellations[0].message)
        XCTAssertTrue(rig.results.isEmpty)
        XCTAssertEqual(rig.capture.stops, 1)
    }

    // R3/R4: one failed segment must not truncate a later recording or trigger auto-send.
    func testFailedSegmentKeepsPartialAndDoesNotStopNextRecording() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        try rig.model.start(channel: .wetype, sendsReturn: true)
        try await eventually { rig.engines[0].started }
        rig.engines[0].emit("第一段已识别。")
        try await eventually { rig.model.text == "第一段已识别。" }
        rig.model.end()
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines[1].started }
        rig.engines[0].resolve(.failure(ASRError("模拟网络断开")))
        try await eventually { rig.engines[0].returned }
        XCTAssertTrue(rig.model.isRecording)
        XCTAssertEqual(rig.capture.stops, 1)
        rig.model.end()
        rig.engines[1].resolve(.success("第二段完整稿。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0], .init(text: "第一段已识别。第二段完整稿。", error: "模拟网络断开", sendsReturn: false))
    }

    // Preview-only input follows upstream non-streaming semantics for a successful empty final.
    func testEmptyFinalWithdrawsProvisionalPreview() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        try rig.model.start(channel: .doubao)
        try await eventually { rig.engines[0].started }
        rig.engines[0].emit("结尾几个字完整保留")
        try await eventually { rig.model.text == "结尾几个字完整保留" }
        rig.model.end()
        rig.engines[0].resolve(.success(""))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0].text, "")
        XCTAssertEqual(rig.updates.last, "")
    }

    // R3: callback ordering must also hold when a vendor emits then returns/throws synchronously.
    func testImmediateEmptyFinalOrFailurePreservesCallbackOrdering() async throws {
        let replies: [(Swift.Result<String, Error>, String?)] = [(.success(""), nil), (.failure(ASRError("同步错误")), "同步错误")]
        for (reply, error) in replies {
            let rig = DictationRig()
            defer { rig.close() }
            rig.configure = { $0.immediateReply = reply }
            try rig.model.start(channel: .wetype)
            try await eventually { rig.results.count == 1 }
            let expected = error == nil ? "" : "同步回调的完整尾字"
            XCTAssertEqual(rig.results[0].text, expected)
            XCTAssertEqual(rig.updates.last, expected)
            XCTAssertTrue(rig.updates.contains("同步回调的完整尾字"))
            XCTAssertEqual(rig.capture.stops, 1)
            XCTAssertEqual(rig.results[0].error, error)
        }
    }

    // R1/R4: opening a microphone can fail during continuation; the old final still belongs here.
    func testStartFailurePreservesPendingSession() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        rig.capture.startError = ASRError("麦克风不可用")
        XCTAssertThrowsError(try rig.model.start(channel: .wetype))
        XCTAssertFalse(rig.model.isActive)
        rig.capture.startError = nil
        try rig.model.start(channel: .wetype)
        try await eventually { rig.engines[0].started }
        rig.engines[0].emit("上一段临时文字")
        try await eventually { rig.model.text == "上一段临时文字" }
        rig.model.end()
        try await eventually { rig.clock.pending == 1 }
        rig.capture.startError = ASRError("麦克风被拔出")
        XCTAssertThrowsError(try rig.model.start(channel: .wetype))
        XCTAssertTrue(rig.model.isActive)
        XCTAssertFalse(rig.model.isRecording)
        XCTAssertEqual(rig.model.text, "上一段临时文字")
        XCTAssertEqual(rig.capture.starts, 1)
        XCTAssertEqual(rig.engines.count, 1)
        rig.engines[0].resolve(.success("上一段完整定稿。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0].text, "上一段完整定稿。")
    }

    // R1/R4: modifier/tap event duplication must not create or stop multiple recordings.
    func testRepeatedStartAndStopAreIdempotent() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        XCTAssertTrue(try rig.model.start(channel: .doubao))
        XCTAssertFalse(try rig.model.start(channel: .wetype))
        try await eventually { rig.engines[0].started }
        rig.model.end()
        rig.model.end()
        XCTAssertEqual(rig.capture.starts, 1)
        XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertEqual(rig.engines.count, 1)
        rig.engines[0].resolve(.success("一次完整定稿。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0].text, "一次完整定稿。")
    }

    // R3/R4: aggregate final is the sole auto-send decision, never a partial or empty result.
    func testSendWaitsForEveryFinalAndRequiresNonemptySuccess() async throws {
        let rig = DictationRig()
        defer { rig.close() }
        try rig.model.start(channel: .wetype)
        rig.model.end()
        try rig.model.start(channel: .wetype, sendsReturn: true)
        rig.model.end()
        try await eventually { rig.engines.allSatisfy(\.started) }
        rig.engines[1].resolve(.success("第二段尾字。"))
        try await eventually { rig.engines[1].returned }
        XCTAssertTrue(rig.results.isEmpty)
        rig.engines[0].resolve(.success("第一段润色稿。"))
        try await eventually { rig.results.count == 1 }
        XCTAssertEqual(rig.results[0], .init(text: "第一段润色稿。第二段尾字。", error: nil, sendsReturn: true))
        try rig.model.start(channel: .wetype, sendsReturn: true)
        rig.model.end()
        try await eventually { rig.engines[2].started }
        rig.engines[2].resolve(.success(""))
        try await eventually { rig.results.count == 2 }
        XCTAssertEqual(rig.results[1], .init(text: "", error: nil, sendsReturn: false))
    }
}
