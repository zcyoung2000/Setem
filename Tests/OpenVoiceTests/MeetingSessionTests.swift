import Combine
import Foundation
import XCTest
@testable import OpenVoice

@MainActor
private final class SimulatedCapture: MeetingAudioCapture {
    private var continuation: AsyncThrowingStream<[Int16], Error>.Continuation?
    private(set) var stopped = false
    var startError: Error?
    func start() async throws -> AsyncThrowingStream<[Int16], Error> {
        if let startError { throw startError }
        let (stream, cont) = AsyncThrowingStream<[Int16], Error>.makeStream()
        continuation = cont
        return stream
    }
    func send(_ value: Int16) {
        continuation?.yield([Int16](repeating: value, count: 320))
    }
    func stop() async { stopped = true; continuation?.finish(); continuation = nil }
}

private final class SessionTestEngine: ASREngine {
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        var count = 0
        for await _ in audio {
            try Task.checkCancellation()
            count += 1
            partial("实时内容 \(count)")
        }
        return "定稿 \(count) 帧"
    }
}

@MainActor
final class MeetingSessionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenVoice-SessionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Meeting session did not reach expected state")
    }

    func testPauseResumeRetainsSessionAndDrainsAudioTail() async throws {
        var sources: [SimulatedCapture] = []
        let model = MeetingSession(captureFactory: {
            let source = SimulatedCapture()
            sources.append(source)
            return source
        }, archiveRoot: try directory(), engineFactory: { _ in SessionTestEngine() }, channels: { [.wetype] })
        model.start()
        try await eventually { model.phase == .recording }
        let url = try XCTUnwrap(model.directory)
        let startedAt = model.record.startedAt
        // Rapid pause/resume requests cannot create a second recorder before tail drain.
        for _ in 0..<7 { sources[0].send(8000) }
        model.pause()
        model.pause()
        model.resume()
        try await eventually { model.phase == .paused }
        XCTAssertTrue(sources[0].stopped)
        XCTAssertEqual(model.record.frameCount, 7)
        XCTAssertFalse(model.isCapturing)
        XCTAssertTrue(model.hasOpenMeeting)
        XCTAssertEqual(model.record.capturePaused, true)
        XCTAssertEqual(model.record.pauses?.count, 1)

        model.resume()
        model.resume()
        try await eventually { model.phase == .recording }
        XCTAssertEqual(sources.count, 2)
        for _ in 0..<11 { sources[1].send(9000) }
        model.pause()
        try await eventually { model.phase == .paused }
        try await eventually { model.record.segments.allSatisfy { $0.state == .complete } }
        XCTAssertEqual(model.directory, url)
        XCTAssertEqual(model.record.startedAt, startedAt)
        XCTAssertEqual(model.record.frameCount, 18)
        XCTAssertEqual(model.record.segments.map(\.startFrame), [0, 7])
        XCTAssertEqual(model.record.segments.map(\.endFrame), [7, 18])
        XCTAssertNotNil(model.record.pauses?[0].endedAt)
        XCTAssertEqual(model.record.pauses?.count, 2)
        XCTAssertTrue(model.record.transcript.contains("恢复"))
        await model.prepareForTermination()
        let archive = try MeetingArchive(directory: url)
        XCTAssertEqual(try archive.frames(from: 0, to: 18).map { $0[0] }, [Int16](repeating: 8000, count: 7) + [Int16](repeating: 9000, count: 11))
        XCTAssertTrue(try archive.recover().captureEnded)
    }

    func testResumeFailureKeepsPriorContentAndCanBeRetried() async throws {
        var sources: [SimulatedCapture] = []
        let model = MeetingSession(captureFactory: {
            let source = SimulatedCapture()
            if sources.count == 1 { source.startError = ASRError("模拟设备被拔出") }
            sources.append(source)
            return source
        }, archiveRoot: try directory(), engineFactory: { _ in SessionTestEngine() }, channels: { [.wetype] })
        model.start()
        try await eventually { model.phase == .recording }
        sources[0].send(8100)
        model.pause()
        try await eventually { model.phase == .paused }
        model.resume()
        try await eventually { model.phase == .paused && sources.count == 2 }
        XCTAssertEqual(model.record.frameCount, 1)
        XCTAssertTrue(model.notice.contains("设备"))
        model.resume()
        try await eventually { model.phase == .recording }
        sources[2].send(8200)
        model.pause()
        try await eventually { model.phase == .paused }
        XCTAssertEqual(model.record.frameCount, 2)
        XCTAssertEqual(model.record.pauses?.count, 2)
        await model.prepareForTermination()
    }

    func testMeterDoesNotInvalidateSessionOrTranscript() {
        let model = MeetingSession()
        var sessionChanges = 0
        var meterChanges = 0
        let session = model.objectWillChange.sink { sessionChanges += 1 }
        let meter = model.meter.objectWillChange.sink { meterChanges += 1 }
        for i in 0..<100 { model.meter.push(Float(i % 10) / 10) }
        XCTAssertGreaterThan(meterChanges, 10)
        XCTAssertEqual(sessionChanges, 0)
        XCTAssertEqual(model.transcriptRevision, 0)
        withExtendedLifetime([session, meter]) {}
    }

    func testFrameCountAndOutOfOrderSnapshotsDoNotTriggerTranscriptScroll() {
        let model = MeetingSession()
        var record = MeetingRecord(startedAt: Date())
        record.segments = [MeetingSegment(id: 0, startFrame: 0, endFrame: 1, text: "同一段文字")]
        record.updateSequence = 1
        model.apply(record)
        let revision = model.transcriptRevision
        record.frameCount = 20
        record.segments[0].endFrame = 20
        record.updateSequence = 3
        model.apply(record)
        XCTAssertEqual(model.transcriptRevision, revision)
        record.updateSequence = 2
        record.segments[0].text = "迟到结果"
        model.apply(record)
        XCTAssertEqual(model.record.segments[0].text, "同一段文字")
        record.updateSequence = 4
        record.segments[0].text = "新的文字"
        model.apply(record)
        XCTAssertEqual(model.transcriptRevision, revision + 1)
    }

    func testExitCannotRaceAResumeOrFinishBeforePersistence() async throws {
        var sources: [SimulatedCapture] = []
        let model = MeetingSession(captureFactory: {
            let source = SimulatedCapture(); sources.append(source); return source
        }, archiveRoot: try directory(), engineFactory: { _ in SessionTestEngine() }, channels: { [.wetype] })
        model.start()
        try await eventually { model.phase == .recording }
        sources[0].send(9000)
        model.pause()
        try await eventually { model.phase == .paused }
        model.exit()
        model.resume()
        await model.prepareForTermination()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(model.phase, .stopped)
        let archive = try MeetingArchive(directory: XCTUnwrap(model.directory))
        XCTAssertTrue(try archive.recover().captureEnded)
    }
}
