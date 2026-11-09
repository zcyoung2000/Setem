import AppKit
import Foundation
import XCTest
@testable import OpenVoice

@MainActor
private final class FailoverClock {
    private var pending: [(TimeInterval, CheckedContinuation<Void, Error>)] = []
    func sleep(_ delay: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { pending.append((delay, $0)) }
    }
    func count(_ delay: TimeInterval) -> Int { pending.filter { $0.0 == delay }.count }
    func advance(_ delay: TimeInterval? = nil) {
        let ready = pending.filter { delay == nil || $0.0 == delay }
        pending.removeAll { delay == nil || $0.0 == delay }
        ready.forEach { $0.1.resume() }
    }
}

@MainActor
private final class FailoverRig {
    let clock = FailoverClock()
    let audio = AsyncStream<[Int16]>.makeStream()
    var engines: [Channel: [ParityEngine]] = [:]
    var leased: [Channel] = []
    var previews: [String] = []
    var result: Result<String, Error>?
    var task: Task<Void, Never>?
    lazy var pool = DictationEnginePool { [unowned self] channel in
        let engine = ParityEngine()
        engines[channel, default: []].append(engine)
        leased.append(channel)
        return engine
    }
    lazy var runner = DictationFailover(pool: pool, sleep: clock.sleep, isSpeech: { _ in true })
    func start(_ channel: Channel = .wetype) {
        task = Task {
            do { result = .success(try await runner.run(audio: audio.stream, channel: channel) { [weak self] in self?.previews.append($0) }) }
            catch { result = .failure(error) }
        }
    }
    func round(_ channel: Channel) -> ParityEngine.Round? { engines[channel]?.first?.rounds.first }
    func send(_ marker: Int16) { audio.continuation.yield([marker]) }
    func close() {
        task?.cancel(); audio.continuation.finish()
        engines.values.flatMap { $0 }.forEach { $0.close() }
        clock.advance()
    }
}

@MainActor
final class DictationFailoverTests: XCTestCase {
    func testEmptyBackupCannotWinOverCapturedSpeechAndThirdChannelReturnsExactFinal() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        rig.start()
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(101)
        rig.round(.wetype)?.partial("已经捕获的完整语音")
        rig.audio.continuation.finish()
        rig.round(.wetype)?.resolve(.failure(URLError(.secureConnectionFailed)))
        try await parityEventually { rig.round(.doubao)?.ended == true }
        rig.round(.doubao)?.resolve(.success(""))
        try await parityEventually { rig.round(.qwen)?.ended == true }
        XCTAssertNil(rig.result, "An empty backup must not silently discard speech")
        XCTAssertEqual(rig.round(.qwen)?.samples, [101])
        rig.round(.qwen)?.resolve(.success("第三渠道恢复的完整定稿，尾字不丢。"))
        try await parityEventually { rig.result != nil }
        XCTAssertEqual(try rig.result?.get(), "第三渠道恢复的完整定稿，尾字不丢。")
    }

    func testFastReplayKeepsEveryFrameWithoutWaitingForOriginalRecordingDuration() async throws {
        let (audio, output) = AsyncStream<[Int16]>.makeStream()
        for value in 1...500 { output.yield([Int16(value)]) }
        output.finish()
        let began = ProcessInfo.processInfo.systemUptime
        var frames: [[Int16]] = []
        for await frame in withLeadingSilence(audio, realtime: false) { frames.append(frame) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2,
                          "Ten seconds of replay must not take ten seconds before network upload")
        XCTAssertEqual(frames.count, 510)
        XCTAssertEqual(Array(frames.dropFirst(10)), (1...500).map { [Int16($0)] })
        XCTAssertTrue(frames.prefix(10).allSatisfy { $0 == [Int16](repeating: 0, count: 320) })
    }

    func testSilenceAndUnchangedPartialsDoNotCauseRepeatedOrPostponedFailover() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        let silent = DictationFailover(pool: rig.pool, sleep: rig.clock.sleep, isSpeech: { _ in false })
        let task = Task { try await silent.run(audio: rig.audio.stream, channel: .wetype, partial: { _ in }) }
        defer { task.cancel() }
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(0)
        try await parityEventually { rig.round(.wetype)?.samples == [0] }
        XCTAssertEqual(rig.clock.count(4), 0)
        rig.audio.continuation.finish()
        try await parityEventually { rig.round(.wetype)?.ended == true }
        rig.round(.wetype)?.resolve(.success(""))
        let value = try await task.value
        XCTAssertEqual(value, "")
        XCTAssertEqual(rig.leased, [.wetype])

        let spoken = FailoverRig()
        defer { spoken.close() }
        spoken.start()
        try await parityEventually { spoken.round(.wetype) != nil }
        spoken.round(.wetype)?.partial("已有预览")
        try await parityEventually { spoken.previews.last == "已有预览" }
        spoken.send(101)
        try await parityEventually { spoken.clock.count(4) > 0 }
        for _ in 0..<20 { spoken.round(.wetype)?.partial("已有预览") }
        // Drain the same main FIFO as production previews before advancing time.
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        spoken.clock.advance(4)
        try await parityEventually { spoken.round(.doubao) != nil }
        XCTAssertEqual(spoken.leased, [.wetype, .doubao])
    }

    func testCaptureFailureAndLateCancelledTimersNeverStartAnotherChannel() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        var failure: String?
        let runner = DictationFailover(pool: rig.pool, sleep: rig.clock.sleep, isSpeech: { _ in true }, captureFailure: { failure })
        let task = Task { try await runner.run(audio: rig.audio.stream, channel: .wetype, partial: { _ in }) }
        defer { task.cancel() }
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(101)
        try await parityEventually { rig.clock.count(4) > 0 }
        failure = "麦克风已断开"
        rig.round(.wetype)?.resolve(.failure(URLError(.networkConnectionLost)))
        do { _ = try await task.value; XCTFail("Capture failure must not be masked") }
        catch { XCTAssertEqual(error.localizedDescription, "麦克风已断开") }
        rig.clock.advance()
        XCTAssertEqual(rig.leased, [.wetype])
    }

    func testInputFailureDoesNotCancelAnActiveProviderFinalAfterItsDeadline() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        var failure: String?
        let runner = DictationFailover(pool: rig.pool, sleep: rig.clock.sleep, isSpeech: { _ in true }, captureFailure: { failure })
        let task = Task { try await runner.run(audio: rig.audio.stream, channel: .wetype, partial: { _ in }) }
        defer { task.cancel() }
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(101)
        try await parityEventually { rig.round(.wetype)?.samples == [101] }
        failure = "麦克风音频回调已停滞"
        rig.audio.continuation.finish()
        try await parityEventually { rig.round(.wetype)?.ended == true }
        rig.clock.advance()
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        XCTAssertEqual(rig.leased, [.wetype])
        rig.round(.wetype)?.resolve(.success("已经录到的完整最终稿。"))
        let text = try await task.value
        XCTAssertEqual(text, "已经录到的完整最终稿。")
    }

    func testProductionAppKeepsOneHUDAndInsertsOnlyBackupFinalWithoutChangingSelection() async throws {
        _ = NSApplication.shared
        let suite = "Setem-Failover-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("wetype", forKey: "channel")
        let capture = ParityCapture(), primary = ParityEngine(), backup = ParityEngine()
        let hud = HUD(defaults: defaults, reduceMotion: { true })
        var inserted: [(String, Bool)] = [], backupChannels: [Channel] = []
        let app = AppDelegate(capture: DictationCapture(start: capture.start, stop: capture.stop),
            enginePool: DictationEnginePool { _ in primary }, hud: hud, defaults: defaults,
            replayPool: DictationEnginePool { channel in backupChannels.append(channel); return backup },
            insertText: { inserted.append(($0, $1)) })
        defer {
            app.dictation.cancel(); capture.close(); primary.close(); backup.close(); hud.hide()
            defaults.removePersistentDomain(forName: suite)
        }
        app.begin(isTap: true, sendOnFinish: true)
        try await parityEventually { primary.rounds.count == 1 }
        capture.send(101)
        primary.rounds[0].resolve(.failure(URLError(.secureConnectionFailed)))
        try await parityEventually { backup.rounds.count == 1 }
        XCTAssertEqual(capture.stops, 0)
        XCTAssertTrue(app.dictation.isRecording)
        XCTAssertTrue(hud.isVisible)
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "channel"), "wetype")
        capture.tail = 102
        app.end()
        try await parityEventually { backup.rounds[0].ended }
        XCTAssertEqual(backup.rounds[0].samples, [101, 102])
        backup.rounds[0].resolve(.success("无需重说，完整文字只输入一次。"))
        try await parityEventually { inserted.count == 1 }
        XCTAssertEqual(inserted[0].0, "无需重说，完整文字只输入一次。")
        XCTAssertTrue(inserted[0].1)
        XCTAssertFalse(hud.isVisible)
        XCTAssertEqual(backupChannels, [.doubao])
        primary.rounds[0].partial("迟到旧稿")
        await Task.yield()
        XCTAssertEqual(inserted.count, 1)
    }

    func testOldFallbackFinalCannotStopResumedCaptureAndSegmentsKeepExactOrder() async throws {
        let capture = ParityCapture()
        var primary: [ParityEngine] = [], backups: [ParityEngine] = [], results: [DictationSession.Result] = []
        let pool = DictationEnginePool { _ in let e = ParityEngine(); primary.append(e); return e }
        let replayPool = DictationEnginePool { _ in let e = ParityEngine(); backups.append(e); return e }
        let model = DictationSession(startCapture: capture.start, stopCapture: capture.stop,
            enginePool: pool, replayPool: replayPool, failoverPolicy: .automatic)
        model.onFinish = { results.append($0) }
        defer { model.cancel(); capture.close(); primary.forEach { $0.close() }; backups.forEach { $0.close() } }
        try model.start(channel: .wetype, sendsReturn: true)
        try await parityEventually { primary.first?.rounds.count == 1 }
        capture.send(101); model.end()
        primary[0].rounds[0].resolve(.failure(URLError(.networkConnectionLost)))
        try await parityEventually { backups.first?.rounds.count == 1 && backups[0].rounds[0].ended }
        try model.start(channel: .qwen)
        try await parityEventually { primary.count == 2 && primary[1].rounds.count == 1 }
        capture.send(201)
        backups[0].rounds[0].resolve(.success("第一段完整定稿。"))
        try await parityEventually { model.text == "第一段完整定稿。" }
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertTrue(results.isEmpty)
        model.end()
        try await parityEventually { primary[1].rounds[0].ended }
        primary[1].rounds[0].resolve(.success("第二段保留完整尾字。"))
        try await parityEventually { results.count == 1 }
        XCTAssertEqual(results, [.init(text: "第一段完整定稿。第二段保留完整尾字。", error: nil, sendsReturn: true)])
        XCTAssertEqual(capture.stops, 2)
        XCTAssertTrue(pool.take(.wetype).engine === primary[1])
    }

    func testPrimaryCanRecoverAndWinBeforeTheHedgedBackup() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        rig.start()
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(101)
        try await parityEventually { rig.clock.count(4) > 0 }
        rig.clock.advance(4)
        try await parityEventually { rig.round(.doubao) != nil }
        rig.audio.continuation.finish()
        try await parityEventually { rig.round(.wetype)?.ended == true }
        rig.round(.wetype)?.resolve(.success("恢复后的主渠道完整定稿。"))
        try await parityEventually { rig.result != nil }
        rig.round(.doubao)?.partial("迟到备选预览")
        rig.round(.doubao)?.resolve(.success("迟到备选定稿"))
        try await parityEventually { rig.round(.doubao)?.returned == true }
        XCTAssertEqual(try rig.result?.get(), "恢复后的主渠道完整定稿。")
        XCTAssertFalse(rig.previews.contains("迟到备选预览"))
    }

    func testStalledWarmupCannotBlockBackupOrReturnItsEngineToThePool() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        let lease = rig.pool.take(.wetype)
        let primary = try XCTUnwrap(lease.engine as? ParityEngine)
        primary.blocksPreparation = true
        rig.pool.reuse(primary, channel: .wetype)
        rig.pool.prewarm(.wetype)
        try await parityEventually { primary.preparing }
        rig.start(); rig.send(101)
        try await parityEventually { rig.clock.count(4) > 0 }
        rig.clock.advance(4)
        try await parityEventually { rig.round(.doubao) != nil }
        rig.audio.continuation.finish()
        try await parityEventually { rig.round(.doubao)?.ended == true }
        rig.round(.doubao)?.resolve(.success("握手挂起仍能容灾完成。"))
        try await parityEventually { rig.result != nil }
        primary.prepared()
        await Task.yield()
        XCTAssertTrue(primary.rounds.isEmpty)
        XCTAssertFalse(rig.pool.take(.wetype).engine === primary)
        XCTAssertEqual(try rig.result?.get(), "握手挂起仍能容灾完成。")
    }

    func testTLSFailureReplaysFromFirstFrameAndKeepsLiveTailWithOneExactFinal() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        rig.start()
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(101); rig.send(102)
        try await parityEventually { rig.round(.wetype)?.samples == [101, 102] }
        rig.round(.wetype)?.partial("微信的旧临时稿")
        rig.round(.wetype)?.resolve(.failure(URLError(.secureConnectionFailed)))
        try await parityEventually { rig.round(.doubao) != nil }
        rig.send(103); rig.audio.continuation.finish()
        try await parityEventually { rig.round(.doubao)?.ended == true }
        XCTAssertEqual(rig.round(.doubao)?.samples, [101, 102, 103])
        rig.round(.doubao)?.partial("备选的完整临时稿")
        try await parityEventually { rig.previews.last == "备选的完整临时稿" }
        rig.round(.wetype)?.partial("迟到的旧文字不能覆盖")
        rig.round(.doubao)?.resolve(.success("容灾后的完整润色稿，保留最后一个尾字。"))
        try await parityEventually { rig.result != nil }
        XCTAssertEqual(try rig.result?.get(), "容灾后的完整润色稿，保留最后一个尾字。")
        XCTAssertFalse(rig.previews.contains("迟到的旧文字不能覆盖"))
        XCTAssertEqual(rig.leased, [.wetype, .doubao])
    }

    func testSpeechStallStartsBackupWithoutWaitingForHungPrimaryCancellation() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        rig.start()
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(101)
        try await parityEventually { rig.clock.count(4) > 0 }
        rig.clock.advance(4)
        try await parityEventually { rig.round(.doubao) != nil }
        rig.audio.continuation.finish()
        try await parityEventually { rig.round(.doubao)?.ended == true }
        rig.round(.doubao)?.resolve(.success("主连接挂起时仍可完整完成。"))
        try await parityEventually { rig.result != nil }
        XCTAssertEqual(try rig.result?.get(), "主连接挂起时仍可完整完成。")
        XCTAssertFalse(rig.round(.wetype)?.returned ?? true)
        rig.round(.wetype)?.resolve(.success("旧渠道迟到的结果"))
        try await parityEventually { rig.round(.wetype)?.returned == true }
        XCTAssertEqual(try rig.result?.get(), "主连接挂起时仍可完整完成。")
    }

    func testFinalDeadlineStartsBackupEvenAfterPrimaryHasPreviewed() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        rig.start()
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(101)
        rig.round(.wetype)?.partial("原渠道预览仍然可见")
        rig.audio.continuation.finish()
        try await parityEventually { rig.clock.count(2) > 0 }
        rig.clock.advance(2)
        try await parityEventually { rig.round(.doubao) != nil }
        XCTAssertEqual(rig.previews.last, "原渠道预览仍然可见")
        try await parityEventually { rig.round(.doubao)?.ended == true }
        XCTAssertEqual(rig.round(.doubao)?.samples, [101])
        rig.round(.doubao)?.resolve(.success("停止后的完整定稿。"))
        try await parityEventually { rig.result != nil }
        XCTAssertEqual(try rig.result?.get(), "停止后的完整定稿。")
    }

    func testSecondFailureUsesThirdChannelAndOnlyExhaustionReportsError() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        rig.start(); rig.audio.continuation.finish()
        try await parityEventually { rig.round(.wetype) != nil }
        rig.round(.wetype)?.resolve(.failure(URLError(.networkConnectionLost)))
        try await parityEventually { rig.round(.doubao) != nil }
        XCTAssertNil(rig.result)
        rig.round(.doubao)?.resolve(.failure(URLError(.cannotConnectToHost)))
        try await parityEventually { rig.round(.qwen) != nil }
        XCTAssertNil(rig.result)
        rig.round(.qwen)?.resolve(.failure(URLError(.notConnectedToInternet)))
        try await parityEventually { rig.result != nil }
        XCTAssertThrowsError(try rig.result?.get())
        XCTAssertEqual(rig.leased, [.wetype, .doubao, .qwen])
    }

    func testCancellationNeverStartsFallbackAndOfflineNeverUploadsElsewhere() async throws {
        for channel in [Channel.wetype, .offline] {
            let rig = FailoverRig()
            defer { rig.close() }
            rig.start(channel)
            try await parityEventually { rig.round(channel) != nil }
            if channel == .offline { rig.round(channel)?.resolve(.failure(ASRError("本地引擎失败"))) }
            else { rig.task?.cancel() }
            try await parityEventually { rig.result != nil }
            rig.clock.advance()
            XCTAssertEqual(rig.leased, [channel])
            XCTAssertThrowsError(try rig.result?.get())
        }
    }

    func testPrimaryEmptySuccessKeepsExistingSemanticsAndHealthyPrimaryIsReused() async throws {
        let rig = FailoverRig()
        defer { rig.close() }
        rig.start()
        try await parityEventually { rig.round(.wetype) != nil }
        rig.send(101); rig.audio.continuation.finish()
        try await parityEventually { rig.round(.wetype)?.ended == true }
        rig.round(.wetype)?.partial("空定稿应撤回的预览")
        rig.round(.wetype)?.resolve(.success(""))
        try await parityEventually { rig.result != nil }
        XCTAssertEqual(try rig.result?.get(), "")
        XCTAssertEqual(rig.leased, [.wetype])
        let lease = rig.pool.take(.wetype)
        XCTAssertTrue(lease.engine === rig.engines[.wetype]?.first)
    }
}
