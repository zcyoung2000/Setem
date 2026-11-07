import Foundation
import Network
import CryptoKit
import XCTest
@testable import OpenVoice

/// Loopback only: accept TCP without completing the WebSocket handshake. An orphaned
/// URLSession task would keep waiting here, so a failed assertion cannot be masked by EOF.
private final class SocketTestServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "openvoice.socket-lifetime-test")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var ready = false
    var isReady: Bool { lock.withLock { ready } }
    var hasConnection: Bool { lock.withLock { !connections.isEmpty } }

    func upgradeToWebSocket() async throws {
        guard let connection = lock.withLock({ connections.first }) else { throw ASRError("回环连接尚未建立") }
        var request = Data()
        while !request.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)) {
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ASRError(complete ? "回环连接关闭" : "空握手")) }
                }
            }
            request.append(bytes)
        }
        guard let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else { throw ASRError("缺少握手 key") }
        let key = line.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
        let digest = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        try await send(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(digest)\r\n\r\n".utf8))
    }

    func send(_ data: Data) async throws {
        guard let connection = lock.withLock({ connections.first }) else { throw ASRError("回环连接尚未建立") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.lock.withLock { self.ready = true } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    func close() {
        listener.cancel()
        let pending = lock.withLock { connections }
        for connection in pending { connection.cancel() }
    }
}

private final class SocketStateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var cancelled = false
    var isReady: Bool { lock.withLock { ready } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func note(_ state: NWConnection.State) {
        lock.withLock {
            if case .ready = state { ready = true }
            if case .cancelled = state { cancelled = true }
        }
    }
}

/// R6: docs/dictation-baseline.md. Exercise real Foundation/Network task ownership,
/// with no public endpoint, speech content, microphone or Accessibility permission.
@MainActor
final class ConnectionLifetimeTests: XCTestCase {
    func testCancelledWebSocketReadClosesConnectionWithoutWaitingForReply() async throws {
        let server = try SocketTestServer()
        defer { server.close() }
        try await eventually { server.isReady }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let port = try XCTUnwrap(server.listener.port)
        let socket = OpenVoice.WebSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1:\(port.rawValue)/")!), session: session)
        var finished = false
        let read = Task { () throws -> Data in
            defer { finished = true }
            return try await socket.receive(timeout: 15)
        }
        defer { read.cancel(); socket.close() }
        try await eventually { server.hasConnection }
        try await server.upgradeToWebSocket()
        read.cancel()
        try await eventually { finished }
        XCTAssertFalse(socket.alive)
        if case .success = await read.result { XCTFail("Cancelled read must fail") }
    }

    func testSuccessfulWebSocketReadsKeepTheConnectionReusable() async throws {
        let server = try SocketTestServer()
        defer { server.close() }
        try await eventually { server.isReady }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let port = try XCTUnwrap(server.listener.port)
        let socket = OpenVoice.WebSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1:\(port.rawValue)/")!), session: session)
        defer { socket.close() }
        let first = Task { try await socket.receive(timeout: 5) }
        try await eventually { server.hasConnection }
        try await server.upgradeToWebSocket()
        try await server.send(Data([0x82, 3]) + Data("one".utf8))
        let one = try await first.value
        XCTAssertEqual(one, Data("one".utf8))
        XCTAssertTrue(socket.alive)
        let second = Task { try await socket.receive(timeout: 5) }
        try await server.send(Data([0x82, 3]) + Data("two".utf8))
        let two = try await second.value
        XCTAssertEqual(two, Data("two".utf8))
        XCTAssertTrue(socket.alive, "Cancelling the losing timeout task must not close a successful read")
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Connection did not reach expected state", file: file, line: line)
        throw ASRError("测试等待超时")
    }

    private func tasks(_ session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    func testReleasingWebSocketCancelsUnderlyingTask() async throws {
        let server = try SocketTestServer()
        defer { server.close() }
        try await eventually { server.isReady }
        let port = try XCTUnwrap(server.listener.port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port.rawValue)/"))
        var socket: OpenVoice.WebSocket? = OpenVoice.WebSocket(request: URLRequest(url: url), session: session)
        weak var released = socket
        let pending = await tasks(session)
        let underlying = try XCTUnwrap(pending.first)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(underlying.state, .running)
        socket = nil
        XCTAssertNil(released)
        try await eventually { underlying.state == .completed }
        let remaining = await tasks(session)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRetainedWebSocketStaysOpenUntilLastOwnerReleasesIt() async throws {
        let server = try SocketTestServer()
        defer { server.close() }
        try await eventually { server.isReady }
        let port = try XCTUnwrap(server.listener.port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port.rawValue)/"))
        var socket: OpenVoice.WebSocket? = OpenVoice.WebSocket(request: URLRequest(url: url), session: session)
        var retained = socket
        weak var released = socket
        socket = nil
        XCTAssertNotNil(released)
        XCTAssertTrue(retained === released)
        let pending = await tasks(session)
        let underlying = try XCTUnwrap(pending.first)
        XCTAssertEqual(underlying.state, .running)
        retained = nil
        XCTAssertNil(released)
        try await eventually { underlying.state == .completed }
    }

    func testReleasingQwenSocketCancelsConnection() async throws {
        let server = try SocketTestServer()
        defer { server.close() }
        try await eventually { server.isReady }
        let port = try XCTUnwrap(server.listener.port)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let state = SocketStateProbe()
        connection.stateUpdateHandler = { state.note($0) }
        connection.start(queue: DispatchQueue(label: "openvoice.qwen-lifetime-test"))
        try await eventually { state.isReady }
        var socket: QwenRawWS? = QwenRawWS(conn: connection)
        socket?.startReading()
        weak var released = socket
        socket = nil
        XCTAssertNil(released)
        try await eventually { if case .cancelled = connection.state { return true }; return false }
    }

    func testQwenSocketReusePreservesPacketsAfterCancelledRead() async throws {
        let server = try SocketTestServer()
        defer { server.close() }
        try await eventually { server.isReady }
        let port = try XCTUnwrap(server.listener.port)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let state = SocketStateProbe()
        connection.stateUpdateHandler = { state.note($0) }
        connection.start(queue: DispatchQueue(label: "openvoice.qwen-reuse-test"))
        try await eventually { state.isReady && server.hasConnection }
        let clock = ParityClock()
        defer { clock.advance() }
        let socket = QwenRawWS(conn: connection, inbox: QwenInbox(sleep: { try await clock.sleep($0) }))
        defer { socket.close() }
        socket.startReading()
        let old = Task { try await socket.receive(timeout: 8) }
        try await eventually { clock.pending == 1 }
        old.cancel()
        do { _ = try await old.value; XCTFail("Previous socket read did not cancel") }
        catch is CancellationError {}

        // Fragmented UTF-8 JSON/text, with a control frame between message frames.
        let first = Data("下一段的首包".utf8), last = Data("与完整尾字".utf8)
        let wire = Data([0x01, UInt8(first.count)]) + first + Data([0x89, 0])
            + Data([0x80, UInt8(last.count)]) + last
        try await server.send(wire)
        let text = try await socket.receive(timeout: 8)
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "下一段的首包与完整尾字")

        // Long cumulative results use the 64-bit WebSocket payload length field.
        let body = Data(repeating: 0x61, count: 66000) + Data("完整结尾。".utf8)
        var header = Data([0x81, 127])
        var length = UInt64(body.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        try await server.send(header + body)
        let long = try await socket.receive(timeout: 8)
        XCTAssertEqual(long.count, body.count)
        XCTAssertTrue(long == body)
        try await server.send(Data([0x88, 0]))
        do { _ = try await socket.receiveOrNil(timeout: 8); XCTFail("Peer close was swallowed as an idle timeout") }
        catch { XCTAssertEqual(error.localizedDescription, "千问 WS 关闭") }
        XCTAssertFalse(socket.alive)
    }
}
