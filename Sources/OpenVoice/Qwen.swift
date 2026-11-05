import CommonCrypto
import CryptoKit
import Foundation
import Network

/// 千问输入法 ASR：独立 WSG（HMAC-SHA1 + AES-128-CBC），不依赖本机 IME。
/// WSS：HTTP/1.1 101 后发 protobuf 二进制帧（attach → asr/send PCM → complete）。
final class QwenEngine: ASREngine {
    private let requireFinalResult: Bool
    init(requireFinalResult: Bool = false) { self.requireFinalResult = requireFinalResult }
    static let ve = "1.2.35.46"
    static let origin = "https://www.qianwen.com"
    static let hmacKey = Data("2d473b000fdb53e617446f805d4eaaacbb324bd16ee9f6d8237abd0ab79c5e48".utf8)
    static let aesKey = Data("a0a6237b2b735a54".utf8)
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 TONGYI_DESKTOP/0.1.0 QuarkPC/ime_voice"

    private var client: Session?

    deinit { client?.close() }

    func prepare() async { _ = try? await channel(fresh: false) }

    private func channel(fresh: Bool) async throws -> (Session, reused: Bool) {
        if !fresh, let c = client, c.alive { return (c, true) }
        client?.close()
        client = nil
        do {
            let c = try await Session.open()
            client = c
            return (c, false)
        } catch {
            QwenDevice.reset()
            throw error
        }
    }

    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        let audio = withLeadingSilence(audio)
        var (c, reused) = try await channel(fresh: false)
        do {
            try await c.ensureAttach()
        } catch {
            guard reused else { throw error }
            c.close()
            if client === c { client = nil }
            (c, _) = try await channel(fresh: true)
            try await c.ensureAttach()
        }

        let transcript = Box(partial: partial)
        let receiver = Task {
            while !Task.isCancelled {
                guard let data = try await c.ws.receiveOrNil(timeout: 8) else { continue }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if ProcessInfo.processInfo.environment["QWEN_DEBUG"] != nil,
                       let s = String(data: data, encoding: .utf8) {
                        fputs("QWEN_DOWN \(s.prefix(800))\n", stderr)
                    }
                    if let d = obj["data"] as? [String: Any],
                       let s = d["sessionId"] as? String, !s.isEmpty {
                        if obj["route"] as? String == "/voice_assistant/channel/attach" {
                        c.noteSession(s, round: d["roundId"] as? String)
                        }
                        if let nr = d["newRoundId"] as? String, !nr.isEmpty {
                            c.noteRound(nr)
                            transcript.setDone()
                        }
                    }
                    Self.ingest(obj, into: transcript)
                }
            }
        }
        defer { receiver.cancel() }

        do {
            var pcm = Data()
            for await frame in audio {
                try Task.checkCancellation()
                pcm.append(contentsOf: frame.withUnsafeBufferPointer { Data(buffer: $0) })
                while pcm.count >= 3840 {
                    let chunk = Data(pcm.prefix(3840))
                    pcm = Data(pcm.dropFirst(3840))
                    try await c.sendAudio(chunk)
                }
            }
            if !pcm.isEmpty {
                if pcm.count < 3840 { pcm.append(Data(repeating: 0, count: 3840 - pcm.count)) }
                try await c.sendAudio(Data(pcm.prefix(3840)))
            }
            try await c.complete()
            for _ in 0..<8 where !transcript.isDone {
                try await Task.sleep(for: .milliseconds(250))
            }
            if requireFinalResult, !transcript.isDone {
                throw ASRError("千问未返回完整定稿，正在切换渠道补转")
            }
            receiver.cancel()
            _ = try? await receiver.value
            c.reset()
            if transcript.result.isEmpty { throw ASRError("千问没有识别文本") }
            return transcript.result
        } catch {
            c.close()
            receiver.cancel()
            _ = try? await receiver.value
            if client === c { client = nil }
            if !requireFinalResult, !Task.isCancelled, !transcript.result.isEmpty { return transcript.result }
            throw error
        }
    }

    fileprivate final class Session {
        let auth: QwenAuth
        let ws: QwenRawWS
        private let stateLock = NSLock()
        private var sessionId = ""
        private var roundId = ""
        private var attached = false
        var alive: Bool { ws.alive }

        private struct State {
            let sessionId: String
            let roundId: String
        }

        private var state: State {
            stateLock.withLock { State(sessionId: sessionId, roundId: roundId) }
        }

        init(auth: QwenAuth, ws: QwenRawWS) {
            self.auth = auth
            self.ws = ws
        }

        static func open() async throws -> Session {
            let auth = try QwenAuth.make()
            return Session(auth: auth, ws: try await QwenRawWS.connect(auth: auth))
        }

        func ensureAttach() async throws {
            if attached, !sessionId.isEmpty { return }
            try await ws.send(binary: QwenEngine.attach(auth: auth))
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, sessionId.isEmpty {
                guard let data = try await ws.receiveOrNil(timeout: 2) else { continue }
                if ProcessInfo.processInfo.environment["QWEN_DEBUG"] != nil,
                   let s = String(data: data, encoding: .utf8) {
                    fputs("QWEN_ATTACH \(s.prefix(1200))\n", stderr)
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let d = obj["data"] as? [String: Any],
                      let s = d["sessionId"] as? String, !s.isEmpty else { continue }
                sessionId = s
                roundId = (d["roundId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ro_\(s)_0"
            }
            guard !sessionId.isEmpty else { throw ASRError("千问 attach 没有 sessionId") }
            attached = true
        }

        func sendAudio(_ pcm: Data) async throws {
            let s = state
            try await ws.send(binary: QwenEngine.asrSend(auth: auth, sessionId: s.sessionId, roundId: s.roundId, pcm: pcm))
        }

        func complete() async throws {
            let s = state
            try await ws.send(binary: QwenEngine.asrComplete(auth: auth, sessionId: s.sessionId, roundId: s.roundId))
        }

        func noteSession(_ id: String, round: String?) {
            stateLock.withLock {
                sessionId = id
                roundId = round.flatMap { $0.isEmpty ? nil : $0 } ?? "ro_\(id)_0"
                attached = true
            }
        }
        func noteRound(_ id: String) {
            stateLock.withLock { roundId = id }
        }
        func reset() {
            stateLock.withLock {
                attached = false
                sessionId = ""
                roundId = ""
            }
        }

        func close() { ws.close() }
    }

    private enum QwenPB {
        static func varint(_ n: Int) -> Data {
            var n = n, d = Data()
            while n > 0x7f { d.append(UInt8((n & 0x7f) | 0x80)); n >>= 7 }
            d.append(UInt8(n)); return d
        }
        static func bytes(_ fn: Int, _ s: String) -> Data { bytes(fn, Data(s.utf8)) }
        static func bytes(_ fn: Int, _ b: Data) -> Data { varint((fn << 3) | 2) + varint(b.count) + b }
        static func kv(_ fn: Int, _ k: String, _ v: String) -> Data { bytes(fn, bytes(1, k) + bytes(2, v)) }
    }

    private static func nowMs() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) }
    private static func attach(auth: QwenAuth) throws -> Data {
        let reqt = nowMs()
        let header: [String: Any] = ["clt-acs-reqt": reqt, "ai_polish_mode": "off"]
        let asr: [String: Any] = [
            "body": [
                "bitDepth": "16", "channel": "mono", "format": "pcm",
                "maxEndSilence": "180000", "maxStartSilence": "180000",
                "sampleRate": "16000", "type": "manualStreamStop",
            ],
            "chid": auth.chid,
            "header": header,
            "param": [:] as [String: Any],
            "route": "/app/live/init",
        ]
        let pipe: [String: Any] = [
            "biz_data": [:] as [String: Any],
            "biz_id": "ai_command",
            "chat_client": "native",
            "client_tm": reqt,
            "endpoint_config": [:] as [String: Any],
            "from": "kkframenew_quark_asr",
            "scene": "voice_input_assistant",
            "ai_polish_mode": "off",
        ]
        let asrJSON = String(data: try JSONSerialization.data(withJSONObject: asr), encoding: .utf8)!
        let pipeJSON = String(data: try JSONSerialization.data(withJSONObject: pipe), encoding: .utf8)!
        return QwenPB.bytes(1, "/voice_assistant/channel/attach")
            + QwenPB.bytes(2, auth.chid)
            + QwenPB.kv(3, "clt-acs-reqt", reqt)
            + QwenPB.kv(5, "asrConfig", asrJSON)
            + QwenPB.kv(5, "pipelineContext", pipeJSON)
            + QwenPB.kv(5, "trigger", "local_device")
    }
    private static func asrSend(auth: QwenAuth, sessionId: String, roundId: String, pcm: Data) -> Data {
        let audio = QwenPB.bytes(1, "audio") + QwenPB.bytes(2, "pcm") + QwenPB.bytes(3, pcm)
        return QwenPB.bytes(1, "/voice_assistant/channel/asr/send")
            + QwenPB.bytes(2, auth.chid)
            + QwenPB.kv(3, "clt-acs-reqt", nowMs())
            + QwenPB.kv(4, "roundId", roundId)
            + QwenPB.kv(4, "sessionId", sessionId)
            + QwenPB.kv(5, "streamInputState", "process")
            + QwenPB.bytes(6, audio)
    }

    private static func asrComplete(auth: QwenAuth, sessionId: String, roundId: String) -> Data {
        QwenPB.bytes(1, "/voice_assistant/channel/asr/complete")
            + QwenPB.bytes(2, auth.chid)
            + QwenPB.kv(3, "clt-acs-reqt", nowMs())
            + QwenPB.kv(4, "roundId", roundId)
            + QwenPB.kv(4, "sessionId", sessionId)
    }

    private final class Box {
        private let lock = NSLock()
        private let partial: (String) -> Void
        private var asr = ""
        private var done = false
        init(partial: @escaping (String) -> Void) { self.partial = partial }
        var result: String { lock.withLock { asr } }
        var isDone: Bool { lock.withLock { done } }
        func setASR(_ s: String) {
            lock.lock(); asr = s; let p = partial; lock.unlock(); p(s)
        }
        func setDone() {
            lock.lock(); done = true; lock.unlock()
        }
    }

    private static func ingest(_ obj: [String: Any], into t: Box) {
        walk(obj, into: t)
    }

    private static func walk(_ any: Any, into t: Box) {
        if let d = any as? [String: Any] {
            if let text = (d["content"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                t.setASR(text)
            }
            for v in d.values { walk(v, into: t) }
        } else if let a = any as? [Any] {
            for v in a { walk(v, into: t) }
        }
    }
}

/// 本机 UTDID 只生成一次，落到 Application Support，会话 chid 仍每次新开。
struct QwenDevice: Codable {
    let utdid: String
    private static let file = appSupportFile("qwen.json")

    static func load() throws -> QwenDevice {
        if let data = try? Data(contentsOf: file),
           let d = try? JSONDecoder().decode(QwenDevice.self, from: data),
           !d.utdid.isEmpty {
            return d
        }
        let d = QwenDevice(utdid: "VK" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
        try? JSONEncoder().encode(d).write(to: file)
        return d
    }

    static func reset() { try? FileManager.default.removeItem(at: file) }
}

struct QwenAuth {
    let utdid: String
    let ut: String
    let chid: String
    let reqt: String
    let sign: String

    static func make() throws -> QwenAuth {
        let utdid = try QwenDevice.load().utdid
        let ut = try encrypt(Array(utdid.utf8))
        let chid = UUID().uuidString.lowercased() + "_1"
        let reqt = String(Int(Date().timeIntervalSince1970 * 1000))
        let input = ut + QwenEngine.ve + chid + reqt
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: QwenEngine.hmacKey))
        let sign = "4ea4" + mac.map { String(format: "%02x", $0) }.joined()
        return QwenAuth(utdid: String(utdid), ut: ut, chid: chid, reqt: reqt, sign: sign)
    }

    var headers: [String: String] {
        [
            "clt-acs-ut": Self.qenc(ut),
            "clt-acs-ve": QwenEngine.ve,
            "clt-acs-kp": "",
            "clt-acs-reqt": reqt,
            "clt-acs-wsgnver": "1",
            "clt-acs-request-params": "chid",
            "clt-acs-sign": sign,
            "clt-acs-caer": "tlbe",
            "x-wpk-reqid": chid,
        ]
    }

    var query: String {
        let utq = Self.qenc(ut)
        return "chid=\(chid)&biz_id=ai_qwen_input&from=kkframenew_quark_asr&uc_param_str=vepffrprsvchut&ut=\(utq)&ve=\(QwenEngine.ve)&pf=8002&pr=qwen&fr=mac&sv=release&ch=qianwen-ime"
    }

    static func qenc(_ s: String) -> String {
        var a = CharacterSet.alphanumerics
        a.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: a) ?? s
    }

    var wsURL: URL { URL(string: "wss://voice-input.qianwen.com/ws/v1/voice?\(query)")! }

    func preference() async throws {
        var req = URLRequest(url: URL(string: "https://voice-input.qianwen.com/api/voice/input/preference/getPreference?\(query)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(QwenEngine.ua, forHTTPHeaderField: "User-Agent")
        req.setValue(QwenEngine.origin, forHTTPHeaderField: "Origin")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ASRError("千问 preference HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["code"] as? String == "00000" else {
            throw ASRError("千问签名校验失败：\(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    private static func encrypt(_ plain: [UInt8]) throws -> String {
        var out = [UInt8](repeating: 0, count: plain.count + 32)
        var n = out.count
        let key = [UInt8](QwenEngine.aesKey)
        let rc = key.withUnsafeBytes { kb in
            plain.withUnsafeBytes { pb in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        kb.baseAddress, key.count, kb.baseAddress,
                        pb.baseAddress, plain.count, &out, out.count, &n)
            }
        }
        guard rc == kCCSuccess else { throw ASRError("千问 AES 失败 \(rc)") }
        var packed: [UInt8] = [0x4e, 0xa4]
        packed.append(contentsOf: out[0..<n])
        return Data(packed).base64EncodedString()
    }
}

/// 裸 TLS + HTTP/1.1 Upgrade。URLSession 会走 h2，Tengine 回 200。
final class QwenRawWS {
    private let conn: NWConnection
    private var buf = Data()
    private var fragments: Data?
    private let q = DispatchQueue(label: "qwen.ws")
    private var dead = false
    private let stateLock = NSLock()
    private let inbox: QwenInbox
    private var reader: Task<Void, Never>?
    var alive: Bool { stateLock.withLock { !dead } }

    init(conn: NWConnection, inbox: QwenInbox = QwenInbox()) { self.conn = conn; self.inbox = inbox }

    deinit { reader?.cancel(); conn.cancel() }

    static func connect(auth: QwenAuth) async throws -> QwenRawWS {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        params.preferNoProxies = true
        let conn = NWConnection(host: "voice-input.qianwen.com", port: 443, using: params)
        let q = DispatchQueue(label: "qwen.nw")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var done = false
            func once(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; if done { return }; done = true; body() }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: once { c.resume() }
                case .failed(let e): once { c.resume(throwing: e) }
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + 8) {
                once { conn.cancel(); c.resume(throwing: ASRError("千问 TLS 连接超时")) }
            }
        }
        let ws = QwenRawWS(conn: conn)
        ws.startReading()
        try await ws.handshake(auth)
        return ws
    }

    private func handshake(_ auth: QwenAuth) async throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var lines = [
            "GET /ws/v1/voice?\(auth.query) HTTP/1.1",
            "Host: voice-input.qianwen.com",
            "Connection: Upgrade",
            "Cache-Control: no-cache",
            "User-Agent: \(QwenEngine.ua)",
            "Upgrade: websocket",
            "Origin: \(QwenEngine.origin)",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Key: \(key)",
        ]
        for (k, v) in auth.headers { lines.append("\(k): \(v)") }
        try await sendRaw(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
        var head = Data()
        let sep = Data("\r\n\r\n".utf8)
        while true {
            if let r = head.range(of: sep) {
                buf = Data(head[r.upperBound...])
                head = Data(head[..<r.upperBound])
                break
            }
            head.append(try await inbox.read(timeout: 8))
            if head.count > 8192 { throw ASRError("千问握手过长") }
        }
        let status = String(data: head.split(separator: 0x0a).first ?? head, encoding: .utf8) ?? ""
        guard status.contains("101") else { throw ASRError("千问 WSS \(status.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    func send(text: String) async throws {
        try await sendRaw(Self.frame(Data(text.utf8), opcode: 0x1))
    }

    func send(binary: Data) async throws {
        try await sendRaw(Self.frame(binary, opcode: 0x2))
    }

    func receive(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let f = try popFrame() { return f }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            buf.append(try await inbox.read(timeout: left))
        }
        throw QwenReadError.timeout
    }

    func receiveOrNil(timeout: TimeInterval) async throws -> Data? {
        do { return try await receive(timeout: timeout) }
        catch QwenReadError.timeout { return nil }
    }

    func close() {
        stateLock.withLock { dead = true }
        reader?.cancel()
        conn.cancel()
        let inbox = self.inbox
        Task { await inbox.finish(ASRError("千问连接已关闭")) }
    }

    func startReading() {
        guard reader == nil else { return }
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled:
                guard let self else { return }
                self.stateLock.withLock { self.dead = true }
            default: break
            }
        }
        let conn = self.conn
        let inbox = self.inbox
        reader = Task {
            do {
                while !Task.isCancelled {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let data, !data.isEmpty { continuation.resume(returning: data) }
                            else if complete { continuation.resume(throwing: ASRError("千问连接已关闭")) }
                            else { continuation.resume(returning: Data()) }
                        }
                    }
                    await inbox.push(data)
                }
            } catch { await inbox.finish(error) }
        }
    }

    private func popFrame() throws -> Data? {
        while true {
            let b = [UInt8](buf)
            guard b.count >= 2 else { return nil }
            let op = b[0] & 0x0f, final = b[0] & 0x80 != 0
            var size = UInt64(b[1] & 0x7f), i = 2
            if size == 126 {
                guard b.count >= 4 else { return nil }
                size = UInt64(b[2]) << 8 | UInt64(b[3]); i = 4
            } else if size == 127 {
                guard b.count >= 10 else { return nil }
                size = b[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; i = 10
            }
            guard size <= 16 * 1024 * 1024 else { throw ASRError("千问 WS 帧过长") }
            let masked = b[1] & 0x80 != 0
            let keyOffset = i
            if masked { i += 4 }
            let n = Int(size)
            guard b.count >= i + n else { return nil }
            var payload = Data(b[i..<(i + n)])
            if masked { for j in 0..<n { payload[j] ^= b[keyOffset + j % 4] } }
            buf = Data(b[(i + n)...])
            if op == 0x8 { close(); throw ASRError("千问 WS 关闭") }
            if op == 0x9 {
                let pong = payload
                Task { try? await sendRaw(Self.frame(pong, opcode: 0xA)) }
            } else if op == 0x1 || op == 0x2 {
                if final { return payload }
                fragments = payload
            } else if op == 0, var message = fragments {
                message.append(payload)
                guard message.count <= 64 * 1024 * 1024 else { throw ASRError("千问 WS 消息过长") }
                fragments = final ? nil : message
                if final { return message }
            }
        }
    }

    private func sendRaw(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: d, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    private static func frame(_ payload: Data, opcode: UInt8) -> Data {
        var mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        var out = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 { out.append(0x80 | UInt8(n)) }
        else if n < 65536 {
            out.append(0x80 | 126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xff))
        } else {
            out.append(0x80 | 127)
            for i in (0..<8).reversed() { out.append(UInt8((n >> (i * 8)) & 0xff)) }
        }
        out.append(contentsOf: mask)
        out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return out
    }
}
