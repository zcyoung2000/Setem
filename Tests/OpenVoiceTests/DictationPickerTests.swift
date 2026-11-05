import Foundation
import XCTest
@testable import OpenVoice

/// Exact outcomes and source snapshot: docs/dictation-parity.md, P4–P8.
@MainActor
final class DictationPickerTests: XCTestCase {
    func testMultiChannelConfigurationMatchesUpstreamNormalization() {
        let supported: [Channel] = [.doubao, .wetype, .qwen]
        XCTAssertEqual(Channel.normalizedMulti(nil, engines: supported), supported)
        XCTAssertEqual(Channel.normalizedMulti([], engines: supported), supported)
        XCTAssertEqual(Channel.normalizedMulti(["qwen", "qwen", "offline", "all", "unknown"], engines: supported), supported)
        XCTAssertEqual(Channel.normalizedMulti(["qwen", "wetype", "qwen", "unknown"], engines: supported), [.wetype, .qwen])
    }

    func testPickerUsesSelectedChannelSetAndPinsItOnResume() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        let selected = Channel.normalizedMulti(["wetype", "qwen"], engines: [.doubao, .wetype, .qwen])
        try rig.model.start(channels: selected)
        XCTAssertEqual(rig.model.rows.map(\.channel), [.wetype, .qwen])
        XCTAssertNil(rig.engines[.doubao])
        let w1 = try rig.engine(.wetype), q1 = try rig.engine(.qwen)
        try await parityEventually { w1.rounds.count == 1 && q1.rounds.count == 1 }
        rig.model.end()
        try rig.model.start(channels: [.doubao, .wetype])
        let w2 = try rig.engine(.wetype, 1), q2 = try rig.engine(.qwen, 1)
        try await parityEventually { w2.rounds.count == 1 && q2.rounds.count == 1 }
        XCTAssertNil(rig.engines[.doubao])
        rig.model.end()
        w2.rounds[0].resolve(.success("Voice"))
        w1.rounds[0].resolve(.success("Open"))
        try await parityEventually { (try? rig.row(.wetype).phase) == .final }
        rig.model.choose(.wetype)
        XCTAssertEqual(rig.choices.first?.text, "OpenVoice")
    }

    func testPickResumeRetainsEveryChannelsFinalsInOrder() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        try rig.model.start(channels: [.doubao, .wetype])
        let d1 = try rig.engine(.doubao), w1 = try rig.engine(.wetype)
        try await parityEventually { d1.rounds.count == 1 && w1.rounds.count == 1 }
        rig.capture.send(101)
        rig.capture.tail = 102
        rig.model.end()
        try rig.model.start(channels: [.qwen]) // Resume pins the original channel set.
        let d2 = try rig.engine(.doubao, 1), w2 = try rig.engine(.wetype, 1)
        try await parityEventually { d2.rounds.count == 1 && w2.rounds.count == 1 && d1.rounds[0].ended && w1.rounds[0].ended }
        XCTAssertNil(rig.engines[.qwen])
        XCTAssertEqual(d1.rounds[0].samples, [101, 102])
        XCTAssertEqual(w1.rounds[0].samples, [101, 102])
        rig.capture.send(201)
        w1.rounds[0].partial("微信第一段临时尾")
        try await parityEventually { rig.speech == 1 }
        w1.rounds[0].partial("微信第一段临时尾")
        d1.rounds[0].resolve(.success("豆包第一段。"))
        w1.rounds[0].resolve(.success("微信第一段。"))
        try await parityEventually { (try? rig.row(.wetype).text) == "微信第一段。" }
        XCTAssertTrue(rig.model.isRecording)
        XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertEqual(rig.speech, 1)
        rig.capture.tail = 202
        rig.model.end()
        try await parityEventually { d2.rounds[0].ended && w2.rounds[0].ended }
        w2.rounds[0].resolve(.success("微信第二段。"))
        d2.rounds[0].resolve(.success("豆包第二段。"))
        try await parityEventually { rig.model.rows.allSatisfy { $0.phase == .final } }
        XCTAssertEqual(try rig.row(.doubao).text, "豆包第一段。豆包第二段。")
        XCTAssertEqual(d2.rounds[0].samples, [201, 202])
        XCTAssertEqual(w2.rounds[0].samples, [201, 202])
        XCTAssertTrue(rig.choices.isEmpty)
        rig.model.choose(.wetype)
        XCTAssertEqual(rig.choices.count, 1)
        XCTAssertEqual(rig.choices.first?.text, "微信第一段。微信第二段。")
    }

    func testPickConfirmationWaitsForPolishedFinal() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        try rig.model.start(channels: [.doubao, .wetype])
        let d = try rig.engine(.doubao), w = try rig.engine(.wetype)
        try await parityEventually { d.rounds.count == 1 && w.rounds.count == 1 }
        w.rounds[0].partial("明天三点不对四点，通知张经")
        try await parityEventually { (try? rig.row(.wetype).text.isEmpty) == false }
        rig.model.choose(.wetype)
        XCTAssertTrue(rig.model.choosePending)
        XCTAssertFalse(rig.model.isRecording)
        XCTAssertEqual(rig.capture.stops, 1)
        d.rounds[0].resolve(.success("其他渠道先返回。"))
        try await parityEventually { (try? rig.row(.doubao).phase) == .final }
        XCTAssertTrue(rig.choices.isEmpty)
        XCTAssertEqual(rig.model.rows[rig.model.selected].channel, .wetype)
        w.rounds[0].resolve(.success("明天四点开会，通知张经理。"))
        try await parityEventually { rig.choices.count == 1 }
        XCTAssertEqual(rig.choices[0].channel, .wetype)
        XCTAssertEqual(rig.choices[0].text, "明天四点开会，通知张经理。")
        w.rounds[0].partial("迟到且缺字")
        rig.model.confirm()
        XCTAssertEqual(rig.choices.count, 1)
    }

    func testPickRejectsFailedAndSkippedRows() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        try rig.model.start(channels: [.doubao, .offline, .wetype], skipped: [.offline])
        let d = try rig.engine(.doubao), w = try rig.engine(.wetype)
        try await parityEventually { d.rounds.count == 1 && w.rounds.count == 1 }
        XCTAssertNil(rig.engines[.offline])
        rig.model.choose(.offline)
        XCTAssertEqual(rig.invalidChoices, 1)
        XCTAssertTrue(rig.model.isRecording)
        d.rounds[0].resolve(.failure(ASRError("模拟连接失败")))
        try await parityEventually { (try? rig.row(.doubao).phase) == .error }
        rig.model.choose(.doubao)
        XCTAssertEqual(rig.invalidChoices, 2)
        XCTAssertTrue(rig.choices.isEmpty)
        rig.model.end()
        w.rounds[0].resolve(.success("完整可用的结果。"))
        try await parityEventually { (try? rig.row(.wetype).phase) == .final }
        rig.model.choose(.wetype)
        XCTAssertEqual(rig.choices.first?.text, "完整可用的结果。")
    }

    func testPendingFailedChoiceFallsBackToFinal() async throws {
        for alternativeFirst in [false, true] {
            let rig = PickerRig()
            defer { rig.close() }
            try rig.model.start(channels: [.doubao, .wetype])
            let d = try rig.engine(.doubao), w = try rig.engine(.wetype)
            try await parityEventually { d.rounds.count == 1 && w.rounds.count == 1 }
            rig.model.choose(.doubao)
            if alternativeFirst {
                w.rounds[0].resolve(.success("可用的完整尾字。"))
                try await parityEventually { (try? rig.row(.wetype).phase) == .final }
                XCTAssertTrue(rig.choices.isEmpty)
            }
            d.rounds[0].resolve(.failure(ASRError("所选渠道失败")))
            if !alternativeFirst {
                try await parityEventually { (try? rig.row(.doubao).phase) == .error }
                XCTAssertTrue(rig.model.choosePending)
                XCTAssertTrue(rig.choices.isEmpty)
                w.rounds[0].resolve(.success("可用的完整尾字。"))
            }
            try await parityEventually { rig.choices.count == 1 }
            XCTAssertEqual(rig.choices[0].channel, .wetype)
            XCTAssertEqual(rig.choices[0].text, "可用的完整尾字。")
        }
    }

    func testResumeClearsPendingChoice() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        try rig.model.start(channels: [.doubao])
        let first = try rig.engine(.doubao)
        try await parityEventually { first.rounds.count == 1 }
        rig.model.confirm()
        try await parityEventually { rig.clock.pending == 1 }
        try rig.model.start(channels: [.doubao])
        let second = try rig.engine(.doubao, 1)
        try await parityEventually { second.rounds.count == 1 }
        XCTAssertFalse(rig.model.choosePending)
        rig.clock.advanceNext()
        try await parityEventually { rig.clock.wakes == 1 }
        XCTAssertTrue(rig.model.isRecording)
        second.rounds[0].resolve(.success("第二段。"))
        first.rounds[0].resolve(.success("第一段。"))
        try await parityEventually { (try? rig.row(.doubao).phase) == .final }
        XCTAssertTrue(rig.choices.isEmpty)
        rig.model.end()
        rig.model.confirm()
        XCTAssertEqual(rig.choices.first?.text, "第一段。第二段。")
    }

    func testPickerDigitsHistoryAndManualSelection() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        rig.defaults.set(["qwen": 5, "doubao": 2, "wetype": 2], forKey: "pickCounts")
        rig.defaults.set("wetype", forKey: "lastPick")
        try rig.model.start(channels: [.doubao, .wetype, .qwen])
        XCTAssertEqual(rig.model.rows.map(\.channel), [.qwen, .doubao, .wetype])
        XCTAssertEqual(rig.model.selected, 2)
        let q = try rig.engine(.qwen), w = try rig.engine(.wetype)
        try await parityEventually { q.rounds.count == 1 && w.rounds.count == 1 }
        q.rounds[0].resolve(.success("更早但未选择的结果。"))
        try await parityEventually { (try? rig.row(.qwen).phase) == .final }
        XCTAssertEqual(rig.model.selected, 2)
        rig.model.move(-1)
        XCTAssertEqual(rig.model.selected, 1)
        rig.model.digit(3)
        XCTAssertEqual(rig.model.selected, 2)
        XCTAssertFalse(rig.model.choosePending)
        rig.model.digit(3)
        XCTAssertTrue(rig.model.choosePending)
        w.rounds[0].resolve(.success("记住这个渠道。"))
        try await parityEventually { rig.choices.count == 1 }
        XCTAssertEqual(rig.defaults.string(forKey: "lastPick"), "wetype")
        XCTAssertEqual((rig.defaults.dictionary(forKey: "pickCounts") as? [String: Int])?["wetype"], 3)
        try rig.model.start(channels: [.doubao, .wetype, .qwen])
        XCTAssertEqual(rig.model.rows.map(\.channel), [.qwen, .wetype, .doubao])
        XCTAssertEqual(rig.model.selected, 1)
    }

    func testFinishedPickerInvalidatesTimeoutAndOldCallbacks() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        try rig.model.start(channels: [.doubao, .wetype])
        let d = try rig.engine(.doubao), w = try rig.engine(.wetype)
        try await parityEventually { d.rounds.count == 1 && w.rounds.count == 1 }
        rig.model.end()
        try await parityEventually { rig.clock.pending == 1 }
        d.rounds[0].resolve(.success("豆包定稿。"))
        w.rounds[0].resolve(.success("微信定稿。"))
        try await parityEventually { rig.model.rows.allSatisfy { $0.phase == .final } }
        rig.clock.advanceNext()
        try await parityEventually { rig.clock.wakes == 1 }
        XCTAssertTrue(rig.model.isActive)
        XCTAssertTrue(rig.cancellations.isEmpty)
        rig.model.cancel()
        try rig.model.start(channels: [.doubao, .wetype])
        try await parityEventually { d.rounds.count == 2 && w.rounds.count == 2 }
        d.rounds[1].partial("新会话完整尾字")
        d.rounds[0].partial("迟到的旧会话文字")
        try await parityEventually { (try? rig.row(.doubao).text) == "新会话完整尾字" }
        XCTAssertTrue(rig.model.isRecording)
        XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertEqual(rig.cancellations.count, 1)
        XCTAssertTrue(rig.choices.isEmpty)
    }

    func testPickerTimeoutKeepsPartialAndCannotStopNextCapture() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        try rig.model.start(channels: [.wetype])
        let old = try rig.engine(.wetype)
        try await parityEventually { old.rounds.count == 1 }
        old.rounds[0].partial("超时前已识别的尾字")
        try await parityEventually { (try? rig.row(.wetype).text) == "超时前已识别的尾字" }
        rig.model.end()
        try await parityEventually { rig.clock.pending == 1 }
        rig.clock.advance()
        try await parityEventually { rig.cancellations.count == 1 }
        XCTAssertEqual(rig.cancellations[0].0, "超时前已识别的尾字")
        XCTAssertEqual(rig.cancellations[0].1, "识别超时")
        try rig.model.start(channels: [.wetype])
        let new = try rig.engine(.wetype, 1)
        try await parityEventually { new.rounds.count == 1 }
        old.rounds[0].partial("迟到片段")
        old.rounds[0].resolve(.success("迟到定稿"))
        new.rounds[0].partial("新录音")
        try await parityEventually { (try? rig.row(.wetype).text) == "新录音" }
        XCTAssertTrue(rig.model.isRecording)
        XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertTrue(rig.choices.isEmpty)
    }

    func testFailedPickerResumePreservesPendingChoice() async throws {
        let rig = PickerRig()
        defer { rig.close() }
        try rig.model.start(channels: [.wetype])
        let engine = try rig.engine(.wetype)
        try await parityEventually { engine.rounds.count == 1 }
        rig.model.confirm()
        rig.capture.startError = ASRError("设备断开")
        XCTAssertThrowsError(try rig.model.start(channels: [.wetype]))
        XCTAssertTrue(rig.model.isActive)
        XCTAssertTrue(rig.model.choosePending)
        engine.rounds[0].resolve(.success("失败续录前的完整定稿。"))
        try await parityEventually { rig.choices.count == 1 }
        XCTAssertEqual(rig.choices[0].text, "失败续录前的完整定稿。")
    }

    func testSendExtensionRequiresHealthyFinalAndTerminatesAllFailure() async throws {
        for healthy in [false, true] {
            let rig = PickerRig()
            defer { rig.close() }
            try rig.model.start(channels: [.doubao, .wetype], sendsReturn: true)
            let d = try rig.engine(.doubao), w = try rig.engine(.wetype)
            try await parityEventually { d.rounds.count == 1 && w.rounds.count == 1 }
            d.rounds[0].partial("网络失败前的中间稿")
            try await parityEventually { rig.speech == 1 }
            rig.model.end()
            d.rounds[0].resolve(.failure(ASRError("连接失败")))
            try await parityEventually { (try? rig.row(.doubao).phase) == .final }
            XCTAssertTrue(rig.choices.isEmpty)
            w.rounds[0].resolve(healthy ? .success("完整且允许发送。") : .failure(ASRError("也失败了")))
            try await parityEventually { !rig.model.isActive }
            if healthy {
                XCTAssertEqual(rig.choices.count, 1)
                XCTAssertEqual(rig.choices[0].text, "完整且允许发送。")
                XCTAssertTrue(rig.choices[0].sendsReturn)
            } else {
                XCTAssertTrue(rig.choices.isEmpty)
                XCTAssertEqual(rig.cancellations.count, 1)
                XCTAssertEqual(rig.cancellations[0].1, "没有可发送的完整识别结果")
            }
        }
    }
}
