import Foundation

/// 豆包输入法流式识别：asr.AsrRequest protobuf over WSS，Opus 20ms 帧
final class DoubaoEngine: ASREngine {
    private let requireFinalResult: Bool
    init(requireFinalResult: Bool = false) { self.requireFinalResult = requireFinalResult }
    private static let wsURL = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws"
    /// Official client 1.4.6's built-in ASR key; settings-discovered keys are rejected on some devices.
    static let appKey = "OrnqKvSSrs"
    private static let ok = 20_000_000
    private static let first: UInt64 = 1, middle: UInt64 = 3, last: UInt64 = 9

    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        // Snapshot per run so reused engines pick up changes and retries keep the same option.
        let punctuation = UserDefaults.standard.object(forKey: "doubaoPunctuation") as? Bool ?? true
        // Strict final recognition owns its replay. Avoid retaining the
        // entire segment a second time while strict final recognition is running.
        if requireFinalResult {
            return try await Self.session(audio, requireFinalResult: true, punctuation: punctuation, partial: partial)
        }
        // Keep the complete recording so a rejected device can be replayed once with a new identity.
        let kept = FrameStore()
        let (live, source) = AsyncStream<[Int16]>.makeStream()
        let keeper = Task {
            for await frame in audio {
                kept.append(frame)
                source.yield(frame)
            }
            source.finish()
        }
        defer { keeper.cancel() }

        do {
            return try await Self.session(live, requireFinalResult: requireFinalResult, punctuation: punctuation, partial: partial)
        } catch let rejection as SessionRejected {
            DoubaoDevice.reset()
            let replay = AsyncStream<[Int16]> { cont in
                Task {
                    for frame in kept.take() { cont.yield(frame) }
                    cont.finish()
                }
            }
            do {
                return try await Self.session(replay, requireFinalResult: false, punctuation: punctuation, partial: partial)
            } catch {
                DoubaoDevice.reset()
                throw ASRError("\(rejection.message)；换设备重试：\(error.localizedDescription)")
            }
        }
    }

    private struct SessionRejected: Error { let message: String }

    private final class FrameStore {
        private let lock = NSLock()
        private var frames: [[Int16]] = []

        func append(_ frame: [Int16]) {
            lock.withLock { frames.append(frame) }
        }

        func take() -> [[Int16]] {
            lock.withLock {
                defer { frames.removeAll() }
                return frames
            }
        }
    }

    private static func session(_ audio: AsyncStream<[Int16]>, requireFinalResult: Bool, punctuation: Bool, partial: @escaping (String) -> Void) async throws -> String {
        let pacedAudio = withLeadingSilence(audio)
        let device = try await DoubaoDevice.load()
        let rid = UUID().uuidString.lowercased()
        var request = URLRequest(url: URL(string: "\(Self.wsURL)?aid=401734&device_id=\(device.did)")!)
        request.setValue(device.phone.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("v2", forHTTPHeaderField: "proto-version")
        request.setValue("true", forHTTPHeaderField: "x-custom-keepalive")
        let ws = WebSocket(request: request)
        defer { ws.close() }

        do {
            try await ws.send(Self.request(token: Self.appKey, method: "StartTask", rid: rid))
            try await Self.expect(ws, "TaskStarted")
            try await ws.send(Self.request(token: Self.appKey, method: "StartSession",
                                           payload: Self.sessionConfig(did: device.did, punctuation: punctuation), rid: rid))
            try await Self.expect(ws, "SessionStarted")
        } catch {
            DoubaoDevice.reset()
            throw error
        }

        let transcript = Transcript(partial: partial)
        let receiver = Task { try await Self.receiveResults(ws, into: transcript) }
        defer { receiver.cancel() }

        let encoder = try Opus(application: Opus.voip, bitrate: 16000, complexity: 5)
        let ts0 = Int(Date().timeIntervalSince1970 * 1000)
        var index = 0
        let meta = { (i: Int) in "{\"extra\":{},\"timestamp_ms\":\(ts0 + i * 20)}" }
        for await frame in pacedAudio {
            try Task.checkCancellation()
            try await ws.send(Self.request(method: "TaskRequest", payload: meta(index),
                                           audio: try encoder.encode(frame), rid: rid,
                                           frame: index == 0 ? Self.first : Self.middle))
            index += 1
        }
        try await ws.send(Self.request(method: "TaskRequest", payload: meta(index), rid: rid, frame: Self.last))
        try await ws.send(Self.request(token: Self.appKey, method: "FinishSession", rid: rid))
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10 + Double(index) / 200))
            ws.close()
        }
        defer { watchdog.cancel() }
        do {
            try await receiver.value
        } catch {
            if requireFinalResult { throw error }
            if transcript.result.isEmpty {
                let message = error.localizedDescription
                if message.contains("Failed") { throw SessionRejected(message: message) }
                throw error
            }
        }
        return transcript.result
    }

    private static func request(token: String = "", method: String, payload: String = "",
                                audio: Data = Data(), rid: String, frame: UInt64 = 0) -> Data {
        let pb = PBuf()
        if !token.isEmpty { pb.s(2, token) }
        pb.s(3, "ASR").s(5, method)
        if !payload.isEmpty { pb.s(6, payload) }
        if !audio.isEmpty { pb.s(7, audio) }
        pb.s(8, rid)
        if frame != 0 { pb.v(9, frame) }
        return pb.data
    }

    private struct Response {
        var event = "", status = 0, message = "", result = ""
        init(_ data: Data) throws {
            let f = try pbParse(data)
            event = f.string(4) ?? ""
            status = Int(Int32(truncatingIfNeeded: f.varint(5) ?? 0))
            message = f.string(6) ?? ""
            result = f.string(7) ?? ""
        }
    }

    private static func expect(_ ws: WebSocket, _ event: String) async throws {
        while true {
            let r = try Response(await ws.receive(timeout: 10))
            if r.event.hasSuffix("Failed") || (r.event == event && r.status != ok) {
                throw ASRError("豆包 \(r.event) \(r.status): \(r.message)")
            }
            if r.event == event { return }
        }
    }

    private static func receiveResults(_ ws: WebSocket, into transcript: Transcript) async throws {
        while true {
            // 静音期间上游不回包，超时只兜底；结束阶段由 watchdog 限时
            let r = try Response(await ws.receive(timeout: 600))
            if !r.result.isEmpty { transcript.update(r.result, sessionFinished: r.event == "SessionFinished") }
            if r.event.hasSuffix("Failed") { throw ASRError("豆包 \(r.event) \(r.status): \(r.message)") }
            if r.event == "SessionFinished" { return }
        }
    }

    private static func sessionConfig(did: String, punctuation: Bool) -> String {
        let cfg: [String: Any] = [
            "audio_info": ["channel": 1, "format": "speech_opus", "sample_rate": 16000],
            "enable_punctuation": punctuation,
            "enable_speech_rejection": true,
            "extra": ["app_name": "oime", "cell_compress_rate": 8, "did": did,
                      "enable_asr_threepass": false, "enable_asr_twopass": true, "input_mode": "stream"],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: cfg), as: UTF8.self)
    }

    /// 上游按句定稿（index 递增，同一句可能再次定稿按 index 覆盖）；展示 = 已定稿句 + 当前句
    final class Transcript {
        private struct Sentence {
            var text: String
            var source: String
            var final: Bool
            var needsFinalAlignment: Bool
        }
        private var sentences: [Int: Sentence] = [:]
        // After a cumulative final, this holds only the raw tail beyond that snapshot.
        private var cumulative: String?
        private var cumulativePrefix: Sentence?
        private var finished = false
        private var nextIndex = 0
        private let partial: (String) -> Void
        private let lock = NSLock()

        init(partial: @escaping (String) -> Void) { self.partial = partial }

        var result: String {
            lock.withLock { rendered() }
        }

        private static func isFinal(_ result: [String: Any]) -> Bool {
            let extra = result["extra"] as? [String: Any]
            return (extra?["nonstream_result"] as? Bool ?? false)
                || (result["is_interim"] as? Bool == false && result["is_vad_finished"] as? Bool == true)
        }

        func update(_ json: String, sessionFinished: Bool = false) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else { return }
            let shown: String? = lock.withLock {
                guard !finished else { return nil }
                // No-index responses contain the whole transcript; other rows are alternatives.
                if !results.contains(where: { ($0["index"] as? Int) != nil }) {
                    guard let first = results.first, let text = first["text"] as? String,
                          !text.isEmpty else { return nil }
                    if sessionFinished || Self.isFinal(first) {
                        let source = (cumulativePrefix?.source ?? "") + (cumulative ?? "")
                        cumulativePrefix = Sentence(text: text, source: source.isEmpty ? text : source,
                                                    final: true, needsFinalAlignment: true)
                        cumulative = nil
                        sentences.removeAll()
                        finished = sessionFinished
                    } else if var prefix = cumulativePrefix {
                        guard let range = Self.sourceRange(for: prefix, in: text[...]),
                              range.lowerBound == text.startIndex,
                              range.upperBound < text.endIndex else { return nil }
                        // A final flag finalizes the snapshot, not future speech. Accept
                        // a new tail without letting the raw prefix undo its polishing.
                        prefix.source = String(text[range])
                        prefix.needsFinalAlignment = false
                        cumulativePrefix = prefix
                        cumulative = String(text[range.upperBound...])
                    } else {
                        cumulative = text
                    }
                    return rendered()
                }
                var changed = false
                for r in results {
                    guard let t = r["text"] as? String, !t.isEmpty else { continue }
                    let idx = r["index"] as? Int ?? nextIndex
                    let final = Self.isFinal(r)
                    guard final || sentences[idx]?.final != true else { continue }
                    let source = final ? (sentences[idx]?.source ?? t) : t
                    let align = final && (sentences[idx]?.final != true || sentences[idx]?.needsFinalAlignment == true)
                    let sentence = Sentence(text: t, source: source, final: final, needsFinalAlignment: align)
                    if cumulativePrefix != nil {
                        // Ignore old indexed callbacks covered by the cumulative final.
                        guard let tail = cumulative, Self.sourceRange(for: sentence, in: tail[...]) != nil else { continue }
                    }
                    sentences[idx] = sentence
                    if final { nextIndex = max(nextIndex, idx + 1) }
                    changed = true
                }
                return changed ? rendered() : nil
            }
            if let shown { partial(shown) }
        }

        /// Overlay each sentence on its source span, leaving unfinalized cumulative text intact.
        /// Remember the source, rather than cutting by the (possibly rewritten) final's length.
        private func rendered() -> String {
            let prefix = cumulativePrefix?.text ?? ""
            let keys = sentences.keys.sorted()
            guard let cumulative else { return joinSentences([prefix] + keys.compactMap { sentences[$0]?.text }) }
            var remaining = cumulative[...]
            var text = ""
            for idx in keys {
                guard var sentence = sentences[idx] else { continue }
                if let range = Self.sourceRange(for: sentence, in: remaining) {
                    text += remaining[..<range.lowerBound] + sentence.text
                    sentence.source = String(remaining[range])
                    sentence.needsFinalAlignment = false
                    sentences[idx] = sentence
                    remaining = remaining[range.upperBound...]
                } else {
                    // The indexed sentence can be newer than the latest cumulative snapshot.
                    // Preserve unmatched text instead of guessing a span and deleting speech.
                    text = joinSentences([text, String(remaining), sentence.text])
                    remaining = remaining[remaining.endIndex...]
                }
            }
            return prefix + text + remaining
        }

        private static func sourceRange(for sentence: Sentence, in text: Substring) -> Range<String.Index>? {
            var range = text.range(of: sentence.source) ?? text.range(of: sentence.text)
                ?? alignedRange(of: sentence.source, in: text)
            if sentence.needsFinalAlignment, sentence.source != sentence.text,
               let finalRange = text.range(of: sentence.text) ?? alignedRange(of: sentence.text, in: text),
               let sourceRange = range, finalRange.overlaps(sourceRange) {
                // A cumulative update may have advanced beyond the last indexed interim.
                range = min(sourceRange.lowerBound, finalRange.lowerBound)..<max(sourceRange.upperBound, finalRange.upperBound)
            }
            guard let range else { return nil }
            var end = range.upperBound
            // A source partial may omit the punctuation supplied by its polished final.
            while sentence.final, end < text.endIndex, "。！？!?.,，、；;：:".contains(text[end]) {
                end = text.index(after: end)
            }
            return range.lowerBound..<end
        }

        /// Locate a lightly rewritten sentence when no indexed raw partial was observed.
        /// Ignore punctuation for alignment only; emit the provider's exact final and raw tail.
        /// The source span is cached above, so unchanged cumulative prefixes use exact matching.
        private static func alignedRange(of source: String, in text: Substring) -> Range<String.Index>? {
            func significant(_ c: Character) -> Bool {
                !c.unicodeScalars.allSatisfy {
                    CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
                }
            }
            let needle = source.filter(significant).map { $0 }
            let positions = text.indices.filter { significant(text[$0]) }
            let haystack = positions.map { text[$0] }
            guard !needle.isEmpty, !haystack.isEmpty else { return nil }
            // Substring edit distance: the preceding raw text is free, but edits inside
            // a candidate cost one. Carry its start so no unmatched prefix is thrown away.
            var costs = [Int](repeating: 0, count: haystack.count + 1)
            var starts = Array(0...haystack.count)
            for (i, c) in needle.enumerated() {
                var next = [Int](repeating: i + 1, count: haystack.count + 1)
                var nextStarts = [Int](repeating: 0, count: haystack.count + 1)
                for j in 1...haystack.count {
                    let diagonal = costs[j - 1] + (c == haystack[j - 1] ? 0 : 1)
                    let deletion = costs[j] + 1
                    let insertion = next[j - 1] + 1
                    if diagonal <= deletion && diagonal <= insertion {
                        next[j] = diagonal
                        nextStarts[j] = starts[j - 1]
                    } else if deletion <= insertion {
                        next[j] = deletion
                        nextStarts[j] = starts[j]
                    } else {
                        next[j] = insertion
                        nextStarts[j] = nextStarts[j - 1]
                    }
                }
                costs = next
                starts = nextStarts
            }
            guard let end = (1...haystack.count).min(by: { costs[$0] < costs[$1] }),
                  costs[end] <= needle.count / 3,
                  starts[end] < end else { return nil }
            return positions[starts[end]]..<text.index(after: positions[end - 1])
        }
    }
}

/// 两侧都不是中日韩字符时补空格
func joinSentences(_ parts: [String]) -> String {
    func cjk(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
    var out = ""
    for t in parts where !t.isEmpty {
        if let a = out.last, let b = t.first, !cjk(a), !cjk(b) { out += " " }
        out += t
    }
    return out
}

/// 设备注册，本地缓存复用
struct DoubaoDevice: Codable {
    let did: String
    let token: String
    let phone: Phone

    init(did: String, token: String, phone: Phone) {
        self.did = did
        self.token = token
        self.phone = phone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        did = try c.decode(String.self, forKey: .did)
        token = try c.decode(String.self, forKey: .token)
        // Older Swift caches did not persist the generated device profile.
        phone = try c.decodeIfPresent(Phone.self, forKey: .phone) ?? Phone.legacy
    }

    private static let file = appSupportFile("doubao.json")
    private static let app: [String: String] = [
        "aid": "401734", "app_name": "oime", "channel": "official",
        "version_code": "100406010", "version_name": "1.4.6",
        "manifest_version_code": "100406010", "update_version_code": "100406010",
        "package": "com.bytedance.android.doubaoime",
    ]

    struct Phone: Codable {
        let brand: String, model: String, os: String, api: String, build: String
        let resolution: String, dpi: String

        static let legacy = Phone(
            brand: "google", model: "Pixel 7 Pro", os: "16", api: "36",
            build: "BP2A.250605.031.A2", resolution: "1080*2340", dpi: "420"
        )
        static let profiles = [
            Phone(brand: "google", model: "Pixel 7 Pro", os: "16", api: "36", build: "BP2A.250605.031.A2", resolution: "1080*2340", dpi: "420"),
            Phone(brand: "google", model: "Pixel 8", os: "15", api: "35", build: "AP4A.250205.002", resolution: "1080*2400", dpi: "420"),
            Phone(brand: "google", model: "Pixel 9", os: "15", api: "35", build: "AP4A.250205.002", resolution: "1080*2424", dpi: "420"),
            Phone(brand: "google", model: "Pixel 6", os: "14", api: "34", build: "AP2A.240805.005", resolution: "1080*2400", dpi: "420"),
            Phone(brand: "samsung", model: "SM-S9210", os: "14", api: "34", build: "UP1A.231005.007", resolution: "1080*2340", dpi: "480"),
            Phone(brand: "samsung", model: "SM-S9280", os: "14", api: "34", build: "UP1A.231005.007", resolution: "1080*2340", dpi: "450"),
            Phone(brand: "samsung", model: "SM-S9180", os: "14", api: "34", build: "UP1A.231005.007", resolution: "1080*2316", dpi: "450"),
            Phone(brand: "Xiaomi", model: "23127PN0CC", os: "14", api: "34", build: "UKQ1.230804.001", resolution: "1200*2670", dpi: "440"),
            Phone(brand: "Xiaomi", model: "2211133C", os: "14", api: "34", build: "UKQ1.230804.001", resolution: "1080*2400", dpi: "440"),
            Phone(brand: "Xiaomi", model: "24129PN74C", os: "15", api: "35", build: "AQ3A.240912.001", resolution: "1200*2670", dpi: "440"),
            Phone(brand: "Redmi", model: "23090RA98C", os: "14", api: "34", build: "UKQ1.231003.002", resolution: "1220*2712", dpi: "440"),
            Phone(brand: "Redmi", model: "23113RKC6C", os: "14", api: "34", build: "UKQ1.231003.002", resolution: "1440*3200", dpi: "560"),
            Phone(brand: "vivo", model: "V2309A", os: "14", api: "34", build: "UP1A.231005.007", resolution: "1260*2800", dpi: "480"),
            Phone(brand: "vivo", model: "V2324A", os: "14", api: "34", build: "UP1A.231005.007", resolution: "1260*2800", dpi: "480"),
            Phone(brand: "OPPO", model: "PHZ110", os: "14", api: "34", build: "UKQ1.231108.001", resolution: "1264*2780", dpi: "480"),
            Phone(brand: "OnePlus", model: "PJD110", os: "14", api: "34", build: "UKQ1.230924.001", resolution: "1440*3168", dpi: "560"),
            Phone(brand: "OnePlus", model: "PJE110", os: "14", api: "34", build: "UKQ1.230924.001", resolution: "1264*2780", dpi: "480"),
        ]
        static func random() -> Phone { profiles.randomElement()! }

        var ua: String {
            "com.bytedance.android.doubaoime/100406010 (Linux; U; Android \(os); en_US; \(model); Build/\(build); Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"
        }

        var params: [String: String] {
            app.merging([
                "device_platform": "android", "os": "android", "os_api": api,
                "os_version": os, "device_type": model, "device_brand": brand,
                "device_model": model, "resolution": resolution, "dpi": dpi,
                "language": "zh", "timezone": "8", "access": "wifi",
                "rom": build, "rom_version": build,
            ]) { _, new in new }
        }
    }

    static func load() async throws -> DoubaoDevice {
        if let data = try? Data(contentsOf: file), let d = try? JSONDecoder().decode(DoubaoDevice.self, from: data) {
            return d
        }
        let d = try await register()
        try? JSONEncoder().encode(d).write(to: file)
        return d
    }

    static func reset() { try? FileManager.default.removeItem(at: file) }

    private static func post(_ base: String, ua: String, query: [String: String],
                             body: Data, contentType: String) async throws -> [String: Any] {
        var comps = URLComponents(string: base)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ASRError("豆包设备注册 HTTP 失败") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func register() async throws -> DoubaoDevice {
        let phone = Phone.random()
        let cdid = UUID().uuidString.lowercased()
        let now = String(Int(Date().timeIntervalSince1970 * 1000))
        let params = phone.params
        var header: [String: Any] = params.mapValues { $0 as Any }
        header.merge([
            "device_id": 0, "install_id": 0, "cdid": cdid,
            "openudid": String(format: "%016x", UInt64.random(in: 0...UInt64.max)),
            "clientudid": UUID().uuidString.lowercased(),
            "region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800,
            "sim_region": "cn", "carrier_region": "cn", "cpu_abi": "arm64-v8a", "build_serial": "unknown",
            "not_request_sender": 0, "sig_hash": "", "google_aid": "", "mc": "", "serial_number": "",
        ]) { _, b in b }
        let body = try JSONSerialization.data(withJSONObject: [
            "magic_tag": "ss_app_log", "header": header, "_gen_time": Int(now)!,
        ] as [String: Any])
        let query = params.merging(["ssmix": "a", "_rticket": now, "cdid": cdid, "ac": "wifi"]) { _, new in new }
        let reg = try await post("https://log-klink.zijieapi.com/service/2/device_register/",
                                 ua: phone.ua, query: query, body: body, contentType: "application/json")
        let did = (reg["device_id_str"] as? String) ?? (reg["device_id"] as? NSNumber)?.stringValue ?? ""
        guard !did.isEmpty, did != "0" else { throw ASRError("豆包设备注册被拒绝") }

        return DoubaoDevice(did: did, token: DoubaoEngine.appKey, phone: phone)
    }
}
