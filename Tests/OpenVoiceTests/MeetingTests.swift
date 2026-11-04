import Foundation
import XCTest
@testable import OpenVoice

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Channel, [Int16])] = []
    private var count = 0
    func add(_ channel: Channel, _ frames: [Int16]) { lock.withLock { entries.append((channel, frames)) } }
    var values: [(Channel, [Int16])] { lock.withLock { entries } }
    var ticks: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private final class StubEngine: ASREngine {
    let runBlock: (AsyncStream<[Int16]>, @escaping (String) -> Void) async throws -> String
    init(_ block: @escaping (AsyncStream<[Int16]>, @escaping (String) -> Void) async throws -> String) { runBlock = block }
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        try await runBlock(audio, partial)
    }
}

private actor MeetingGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if open { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        open = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

final class MeetingTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenVoice-MeetingTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func frame(_ marker: Int16 = 8000) -> [Int16] { [Int16](repeating: marker, count: 320) }

    private func eventually(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for meeting pipeline")
    }

    func testSegmentBoundariesCoverEveryFrameIncludingTail() async throws {
        let archive = try MeetingArchive(directory: directory())
        let probe = Probe()
        let pipeline = try MeetingPipeline(archive: archive, channels: [.wetype], factory: { ch in
            StubEngine { audio, _ in
                var markers: [Int16] = []
                for await frame in audio { markers.append(frame[0]) }
                probe.add(ch, markers)
                return "段落 \(markers.first ?? 0)"
            }
        }, onUpdate: { _ in })
        for i in 0..<1957 { try await pipeline.append(frame(Int16(8000 + i))) }
        try await pipeline.finishCapture()
        try await eventually { await pipeline.snapshot().segments.allSatisfy { $0.state == .complete } }
        let record = await pipeline.snapshot()
        XCTAssertEqual(record.frameCount, 1957)
        XCTAssertEqual(record.segments.map(\.startFrame), [0, 900, 1800])
        XCTAssertEqual(record.segments.map(\.endFrame), [900, 1800, 1957])
        let recorded = probe.values.flatMap(\.1).sorted()
        XCTAssertEqual(recorded, (0..<1957).map { Int16(8000 + $0) })
        try await pipeline.suspend()
    }

    func testProviderFailureReplaysWholeRangeAndIgnoresStalePartial() async throws {
        let probe = Probe()
        let pipeline = try MeetingPipeline(archive: MeetingArchive(directory: directory()), channels: [.doubao, .wetype], factory: { channel in
            StubEngine { audio, partial in
                var markers: [Int16] = []
                for await frame in audio {
                    markers.append(frame[0])
                    if channel == .doubao, markers.count == 3 {
                        _ = probe.next()
                        partial("失败渠道的临时结果")
                        Task {
                            try? await Task.sleep(for: .milliseconds(100))
                            partial("迟到的旧结果，不得覆盖定稿")
                        }
                        throw ASRError("injected disconnect")
                    }
                }
                probe.add(channel, markers)
                return "完整会议内容"
            }
        }, onUpdate: { _ in })
        for i in 0..<5 { try await pipeline.append(frame(Int16(8000 + i))) }
        try await eventually { probe.ticks == 1 }
        for i in 5..<50 { try await pipeline.append(frame(Int16(8000 + i))) }
        try await pipeline.finishCapture()
        try await eventually { await pipeline.snapshot().segments.first?.state == .complete }
        try await Task.sleep(for: .milliseconds(150))
        let record = await pipeline.snapshot()
        XCTAssertEqual(record.segments[0].text, "完整会议内容")
        XCTAssertEqual(record.segments[0].provider, Channel.wetype.title)
        XCTAssertEqual(probe.values.first?.1, (0..<50).map { Int16(8000 + $0) })
        try await pipeline.suspend()
    }

    func testAllProvidersFailThenRecoverFromDiskWithoutDroppingAudio() async throws {
        let url = try directory()
        let pipeline = try MeetingPipeline(archive: MeetingArchive(directory: url), channels: [.doubao, .qwen], factory: { _ in
            StubEngine { audio, _ in
                for await _ in audio { }
                throw ASRError("injected outage")
            }
        }, onUpdate: { _ in })
        for _ in 0..<71 { try await pipeline.append(frame()) }
        try await pipeline.finishCapture()
        try await eventually { await pipeline.snapshot().segments.first?.state == .pending }
        try await pipeline.suspend()
        let archive = try MeetingArchive(directory: url)
        let recovered = try archive.recover()
        XCTAssertEqual(recovered.frameCount, 71)
        XCTAssertEqual(recovered.segments[0].state, .pending)
        let probe = Probe()
        let restored = try MeetingPipeline(archive: archive, record: recovered, channels: [.wetype], factory: { ch in
            StubEngine { audio, _ in
                var markers: [Int16] = []
                for await frame in audio { markers.append(frame[0]) }
                probe.add(ch, markers)
                return "补转成功"
            }
        }, onUpdate: { _ in })
        await restored.retryPending(force: true)
        try await eventually { await restored.snapshot().segments.first?.state == .complete }
        XCTAssertEqual(probe.values.first?.1.count, 71)
        try await restored.suspend()
        let markdown = try String(contentsOf: url.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("补转成功"))
        XCTAssertFalse(markdown.contains("待补转"))
    }

    func testTimeoutMovesToNextProviderEvenWhenFirstIgnoresCancellation() async throws {
        let pipeline = try MeetingPipeline(archive: MeetingArchive(directory: directory()), channels: [.doubao, .wetype], attemptTimeout: 0.05, factory: { channel in
            StubEngine { audio, _ in
                for await _ in audio { }
                if channel == .doubao {
                    // Simulate a vendor callback that will not honor Swift task cancellation.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { continuation.resume() }
                    }
                    return "迟到定稿"
                }
                return "备用渠道定稿"
            }
        }, onUpdate: { _ in })
        try await pipeline.append(frame())
        try await pipeline.finishCapture()
        try await eventually { await pipeline.snapshot().segments.first?.state == .complete }
        let record = await pipeline.snapshot()
        XCTAssertEqual(record.segments[0].text, "备用渠道定稿")
        try await pipeline.suspend()
    }

    func testRecoveryIncludesFramesAfterLastManifestCheckpointAndWAVHeader() throws {
        let url = try directory()
        let archive = try MeetingArchive(directory: url)
        try archive.append(frame(111))
        var record = MeetingRecord(startedAt: Date(), frameCount: 1)
        record.segments = [MeetingSegment(id: 0, startFrame: 0, endFrame: 1, sealed: false, state: .transcribing)]
        try archive.save(record)
        try archive.append(frame(222))
        try archive.append(frame(333))
        let recovered = try archive.recover()
        XCTAssertEqual(recovered.segments.map(\.startFrame), [0, 1])
        XCTAssertEqual(recovered.segments.map(\.endFrame), [1, 3])
        XCTAssertEqual(try archive.frames(from: 0, to: 3).map { $0[0] }, [111, 222, 333])
        let wav = url.appendingPathComponent("export.wav")
        try archive.exportWAV(to: wav)
        let data = try Data(contentsOf: wav)
        XCTAssertEqual(data.count, 44 + 3 * 640)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(Array(data[24..<28]), [0x80, 0x3e, 0, 0]) // 16000 Hz, little endian
    }

    func testMixerAlignsBothSourcesAndPreservesSilentGaps() throws {
        var mixer = MeetingAudioMixer()
        try mixer.add(frame(12000), at: 1)
        try mixer.add(frame(23000), at: 1)
        try mixer.add(frame(-9000), at: 3)
        let output = mixer.drain(until: 4)
        XCTAssertEqual(output.map { $0[0] }, [0, Int16.max, 0, -9000])
        XCTAssertThrowsError(try mixer.add(frame(), at: 0))
    }

    func testSilenceCutsSegmentsButDoesNotTerminateMeeting() {
        var segmenter = MeetingSegmenter()
        for _ in 0..<399 { XCTAssertFalse(segmenter.push(level: 0)) }
        XCTAssertTrue(segmenter.push(level: 0))
        segmenter.reset()
        for _ in 0..<899 { XCTAssertFalse(segmenter.push(level: 0.7)) }
        XCTAssertTrue(segmenter.push(level: 0.7))
    }

    func testEmptySpeechResultFallsBackInsteadOfMarkingAudioComplete() async throws {
        let pipeline = try MeetingPipeline(archive: MeetingArchive(directory: directory()), channels: [.doubao, .wetype], factory: { channel in
            StubEngine { audio, _ in
                for await _ in audio { }
                return channel == .doubao ? "" : "不能丢弃有声音的片段"
            }
        }, onUpdate: { _ in })
        try await pipeline.append(frame())
        try await pipeline.finishCapture()
        try await eventually { await pipeline.snapshot().segments.first?.state == .complete }
        let record = await pipeline.snapshot()
        XCTAssertEqual(record.segments[0].text, "不能丢弃有声音的片段")
        try await pipeline.suspend()
    }

    func testBusyProvidersLeaveBacklogOnDiskAndBoundLiveConcurrency() async throws {
        let gate = MeetingGate()
        let probe = Probe()
        let pipeline = try MeetingPipeline(archive: MeetingArchive(directory: directory()), channels: [.wetype], factory: { channel in
            StubEngine { audio, _ in
                await gate.wait()
                var markers: [Int16] = []
                for await frame in audio { markers.append(frame[0]) }
                probe.add(channel, markers)
                return "第 \(markers.first ?? 0) 段"
            }
        }, onUpdate: { _ in })
        for i in 0..<4513 { try await pipeline.append(frame(Int16(8000 + i))) }
        try await pipeline.finishCapture()
        try await eventually { await gate.arrivals == 3 }
        let busy = await pipeline.snapshot()
        XCTAssertEqual(busy.frameCount, 4513)
        XCTAssertEqual(busy.segments.count, 6)
        XCTAssertEqual(busy.segments.filter { $0.state == .queued }.count, 3)
        await gate.release()
        try await eventually { await pipeline.snapshot().segments.allSatisfy { $0.state == .complete } }
        XCTAssertEqual(probe.values.flatMap(\.1).sorted(), (0..<4513).map { Int16(8000 + $0) })
        try await pipeline.suspend()
    }

    func testOfflineProviderUsesOnlyOneModelSlot() async throws {
        let gate = MeetingGate()
        let pipeline = try MeetingPipeline(archive: MeetingArchive(directory: directory()), channels: [.offline], factory: { _ in
            StubEngine { audio, _ in
                await gate.wait()
                for await _ in audio { }
                return "本地识别内容"
            }
        }, onUpdate: { _ in })
        for _ in 0..<1810 { try await pipeline.append(frame()) }
        try await pipeline.finishCapture()
        try await Task.sleep(for: .milliseconds(150))
        let slots = await gate.arrivals
        XCTAssertEqual(slots, 1)
        await gate.release()
        try await eventually { await pipeline.snapshot().segments.allSatisfy { $0.state == .complete } }
        try await pipeline.suspend()
    }

    func testOldSessionManifestWithoutPauseFieldsStillLoads() throws {
        let record = MeetingRecord(startedAt: Date(), frameCount: 10)
        let encoded = try JSONEncoder().encode(record)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["capturePaused", "pauses", "updateSequence"] { old.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(decoded.frameCount, 10)
        XCTAssertNil(decoded.capturePaused)
        XCTAssertNil(decoded.pauses)
    }
}
