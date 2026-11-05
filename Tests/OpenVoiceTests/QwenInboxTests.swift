import Foundation
import XCTest
@testable import OpenVoice

@MainActor
final class QwenInboxTests: XCTestCase {
    func testCancelledQwenReadCannotConsumeNextRound() async throws {
        let clock = ParityClock()
        let inbox = QwenInbox(sleep: { try await clock.sleep($0) })
        defer { clock.advance() }
        let old = Task { try await inbox.read(timeout: 8) }
        try await parityEventually { clock.pending == 1 }
        old.cancel()
        do { _ = try await old.value; XCTFail("Cancelled reader returned data") }
        catch is CancellationError {} // This read must exit before the next lease.
        let next = Task { try await inbox.read(timeout: 8) }
        try await parityEventually { clock.pending == 2 }
        // A previously cancelled timer also cannot cancel the next round's read.
        clock.advanceNext()
        try await parityEventually { clock.wakes == 1 }
        await inbox.push(Data("下一轮的首包与完整尾字".utf8))
        let result = try await next.value
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "下一轮的首包与完整尾字")
    }

    func testQwenReadTimeoutAndCloseReleaseWaiter() async throws {
        let clock = ParityClock()
        let inbox = QwenInbox(sleep: { try await clock.sleep($0) })
        defer { clock.advance() }
        let pending = Task { try await inbox.read(timeout: 2) }
        try await parityEventually { clock.pending == 1 }
        clock.advanceNext()
        do { _ = try await pending.value; XCTFail("Timed out read returned data") }
        catch { XCTAssertEqual(error.localizedDescription, "服务器响应超时") }
        await inbox.push(Data([1, 2, 3]))
        let buffered = try await inbox.read(timeout: 2)
        XCTAssertEqual(buffered, Data([1, 2, 3]))
        let closed = Task { try await inbox.read(timeout: 2) }
        try await parityEventually { clock.pending == 1 }
        await inbox.finish(ASRError("连接已关闭"))
        do { _ = try await closed.value; XCTFail("Closed read returned data") }
        catch { XCTAssertEqual(error.localizedDescription, "连接已关闭") }
        do { _ = try await inbox.read(timeout: 2); XCTFail("Closed inbox accepted another read") }
        catch { XCTAssertEqual(error.localizedDescription, "连接已关闭") }
    }
}
