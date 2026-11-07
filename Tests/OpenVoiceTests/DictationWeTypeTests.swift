import Foundation
import XCTest
@testable import OpenVoice

private final class WeTypeProbeConnection: WeTypeConnection, @unchecked Sendable {
    struct Request { let packet: WeTypeClient.VoicePacket; let timeout: TimeInterval }
    private let lock = NSLock()
    private var closed = false
    private var requests: [Request] = []
    let reply: (WeTypeClient.VoicePacket) async throws -> (text: String, polished: String)
    var alive: Bool { lock.withLock { !closed } }
    var sent: [Request] { lock.withLock { requests } }

    init(reply: @escaping (WeTypeClient.VoicePacket) async throws -> (text: String, polished: String) = {
        $0.isEnd ? ("", "完整定稿，尾字保留。") : ("临时预览", "")
    }) { self.reply = reply }
    func voice(_ packet: WeTypeClient.VoicePacket, timeout: TimeInterval) async throws -> (text: String, polished: String) {
        lock.withLock { requests.append(Request(packet: packet, timeout: timeout)) }
        return try await reply(packet)
    }
    func close() { lock.withLock { closed = true } }
}

private final class WeTypeProbeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let clients: [WeTypeProbeConnection]
    private var count = 0
    private var clock: TimeInterval = 0
    var opened: Int { lock.withLock { count } }
    var now: TimeInterval {
        get { lock.withLock { clock } }
        set { lock.withLock { clock = newValue } }
    }
    init(_ clients: [WeTypeProbeConnection]) { self.clients = clients }
    func open() throws -> WeTypeConnection {
        try lock.withLock {
            count += 1
            guard count <= clients.count else { throw ASRError("不应额外建立连接") }
            return clients[count - 1]
        }
    }
    func engine() -> WeTypeEngine {
        WeTypeEngine(now: { self.now }, makeClient: { try self.open() })
    }
}

private final class WeTypePreviewProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var values: [String] { lock.withLock { texts } }
    func append(_ text: String) { lock.withLock { texts.append(text) } }
}

/// Controlled server replies, with real production framing/Opus and exact final text.
@MainActor
final class DictationWeTypeTests: XCTestCase {
    func testPolishedOnlyReplyAppearsBeforeAudioEndsAndKeepsExactFinal() async throws {
        let connection = WeTypeProbeConnection { packet in
            packet.isEnd ? ("", "完整润色定稿，最后一个尾字。") : ("", "已经返回的润色预览。")
        }
        let engine = WeTypeProbeFactory([connection]).engine()
        let (audio, source) = AsyncStream<[Int16]>.makeStream()
        let previews = WeTypePreviewProbe()
        var finished = false
        let run = Task { () throws -> String in
            defer { finished = true }
            return try await engine.run(audio: audio) { previews.append($0) }
        }
        defer { source.finish(); run.cancel() }
        try await parityEventually { !connection.sent.isEmpty }
        // A later request proves the first reply has been processed while the
        // input is still open; the final cannot be responsible for the preview.
        for _ in 0..<3 { source.yield(Array(repeating: 321, count: 320)) }
        try await parityEventually { connection.sent.count >= 2 }
        XCTAssertTrue(previews.values.contains("已经返回的润色预览。"))
        XCTAssertFalse(finished)
        source.finish()
        let final = try await run.value
        XCTAssertEqual(final, "完整润色定稿，最后一个尾字。")
        XCTAssertEqual(previews.values.last, "完整润色定稿，最后一个尾字。")
    }

    func testPolishedPreviewFallbackDoesNotReplaceAnExistingRawPreview() async throws {
        let connection = WeTypeProbeConnection { packet in
            if packet.seq == 1 { return ("已有原稿预览。", "") }
            return ("", "最终润色稿，尾字完整。")
        }
        let engine = WeTypeProbeFactory([connection]).engine()
        let previews = WeTypePreviewProbe()
        let final = try await engine.run(audio: audio()) { previews.append($0) }
        XCTAssertEqual(previews.values, ["已有原稿预览。"])
        XCTAssertEqual(final, "最终润色稿，尾字完整。")
    }

    private func audio() -> AsyncStream<[Int16]> {
        AsyncStream { out in
            for value: Int16 in [123, 456, 789] { out.yield(Array(repeating: value, count: 320)) }
            out.finish()
        }
    }

    func testIdleConnectionExpiresWithoutPrewarmExtendingItsLife() async throws {
        let old = WeTypeProbeConnection(), fresh = WeTypeProbeConnection()
        let factory = WeTypeProbeFactory([old, fresh])
        let engine = factory.engine()
        await engine.prepare()
        factory.now = 50
        await engine.prepare()
        XCTAssertEqual(factory.opened, 1)
        factory.now = 61
        await engine.prepare()
        XCTAssertEqual(factory.opened, 2)
        XCTAssertFalse(old.alive)
        let final = try await engine.run(audio: audio(), partial: { _ in })
        XCTAssertEqual(final, "完整定稿，尾字保留。")
        XCTAssertTrue(old.sent.isEmpty, "Replace stale connections before sending audio")
    }

    func testSuccessfulReplyRefreshesIdleAgeAndRecentConnectionIsReused() async throws {
        let old = WeTypeProbeConnection(), fresh = WeTypeProbeConnection()
        let factory = WeTypeProbeFactory([old, fresh])
        let engine = factory.engine()
        await engine.prepare()
        factory.now = 50
        let final = try await engine.run(audio: audio(), partial: { _ in })
        XCTAssertEqual(final, "完整定稿，尾字保留。")
        factory.now = 100
        await engine.prepare()
        XCTAssertEqual(factory.opened, 1, "Recent successful speech keeps the connection reusable")
        factory.now = 111
        await engine.prepare()
        XCTAssertEqual(factory.opened, 2, "A prewarm check without traffic must not extend idle age")
    }

    func testReusedFirstPacketRetriesUnchangedAndPreservesFinalTail() async throws {
        let old = WeTypeProbeConnection { _ in throw ASRError("首包响应超时") }
        let fresh = WeTypeProbeConnection()
        let factory = WeTypeProbeFactory([old, fresh])
        let engine = factory.engine()
        await engine.prepare()
        let final = try await engine.run(audio: audio(), partial: { _ in })
        XCTAssertEqual(final, "完整定稿，尾字保留。")
        XCTAssertEqual(factory.opened, 2)
        let failed = try XCTUnwrap(old.sent.first)
        let retry = try XCTUnwrap(fresh.sent.first)
        XCTAssertEqual(failed.timeout, 3)
        XCTAssertEqual(retry.timeout, 15, "Fresh connections and final replies retain their full budget")
        XCTAssertEqual(failed.packet.voiceId, retry.packet.voiceId)
        XCTAssertEqual(failed.packet.opus, retry.packet.opus)
        XCTAssertEqual(failed.packet.seq, retry.packet.seq)
        XCTAssertEqual(failed.packet.totalBytes, retry.packet.totalBytes)
        XCTAssertEqual(failed.packet.isEnd, retry.packet.isEnd)
        XCTAssertEqual(fresh.sent.map(\.packet.seq), Array(1...fresh.sent.count))
        XCTAssertTrue(fresh.sent.allSatisfy { $0.timeout == 15 })
        XCTAssertTrue(fresh.sent.last?.packet.isEnd == true)
    }

    func testCancellationOfReusedFirstPacketNeverReconnects() async throws {
        let gate = ParityClock()
        let old = WeTypeProbeConnection { _ in
            try await gate.sleep(0)
            try Task.checkCancellation()
            return ("旧文字", "")
        }
        let fresh = WeTypeProbeConnection()
        let factory = WeTypeProbeFactory([old, fresh])
        let engine = factory.engine()
        await engine.prepare()
        let run = Task { try await engine.run(audio: audio(), partial: { _ in XCTFail("Cancelled speech must not publish") }) }
        defer { run.cancel(); gate.advance() }
        try await parityEventually { gate.pending == 1 }
        run.cancel()
        gate.advance()
        do { _ = try await run.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(factory.opened, 1, "Esc must not create or retry a new connection")
        XCTAssertTrue(fresh.sent.isEmpty)
        XCTAssertFalse(old.alive)
    }
}
