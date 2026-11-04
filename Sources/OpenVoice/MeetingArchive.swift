import Foundation

struct MeetingSegment: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, transcribing, retrying, pending, complete }
    let id: Int
    let startFrame: Int
    var endFrame: Int
    var sealed = false
    var hasSignal = false
    var text = ""
    var provider = ""
    var state = State.queued
    var error = ""
    var startTime: TimeInterval { Double(startFrame) * 0.02 }
    var duration: TimeInterval { Double(endFrame - startFrame) * 0.02 }
}

struct MeetingRecord: Codable {
    struct Pause: Codable, Equatable {
        let frame: Int
        let beganAt: Date
        var endedAt: Date?
    }
    let startedAt: Date
    var frameCount = 0
    var segments: [MeetingSegment] = []
    var captureEnded = false
    var captureError = ""
    // Optional additions keep sessions created by earlier builds readable.
    var capturePaused: Bool?
    var pauses: [Pause]?
    var updateSequence: UInt64?

    var transcript: String {
        let heading = "# 会议转写 · \(startedAt.formatted(date: .numeric, time: .shortened))\n\n"
        return heading + segments.map { segment in
            let state = segment.state == .complete ? "" : " · 待补转"
            let text = segment.text.isEmpty ? (segment.state == .complete ? "（静音）" : "（音频已保存，待补转）") : segment.text
            return "[\(meetingTimestamp(segment.startTime))]\(state)\n\(text)"
        }.joined(separator: "\n\n") + (pauses ?? []).map { pause in
            let resumed = pause.endedAt.map { "，\($0.formatted(date: .omitted, time: .standard)) 恢复" } ?? ""
            return "\n\n[\(meetingTimestamp(Double(pause.frame) * 0.02))] \(pause.beganAt.formatted(date: .omitted, time: .standard)) 暂停收音\(resumed)"
        }.joined() + (captureError.isEmpty ? "\n" : "\n\n收音中断：\(captureError)\n")
    }
}

func meetingTimestamp(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
}

/// Accessed only by MeetingPipeline's actor. PCM is appended before it is sent to any provider.
/// One file for the entire meeting avoids retaining an hours-long recording in RAM.
final class MeetingArchive {
    static var root: URL { appSupportDirectory().appendingPathComponent("Meetings", isDirectory: true) }
    let directory: URL
    private let audio: FileHandle
    private(set) var frameCount: Int
    private var lastSync = Date.distantPast
    static let frameBytes = FrameConverter.frame * MemoryLayout<Int16>.size

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("audio.pcm")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ASRError("无法创建会议音频文件")
            }
        }
        audio = try FileHandle(forUpdating: url)
        let bytes = try audio.seekToEnd()
        frameCount = Int(bytes) / Self.frameBytes
        // A power failure can leave a partial frame; never replay uninitialized samples.
        try audio.truncate(atOffset: UInt64(frameCount * Self.frameBytes))
    }

    deinit { try? audio.close() }

    func append(_ frame: [Int16]) throws {
        guard frame.count == FrameConverter.frame else { throw ASRError("会议音频帧长度错误") }
        try frame.withUnsafeBytes { try audio.write(contentsOf: $0) }
        frameCount += 1
        if Date().timeIntervalSince(lastSync) >= 1 {
            try audio.synchronize()
            lastSync = Date()
        }
    }

    func frames(from start: Int, to end: Int) throws -> [[Int16]] {
        guard start >= 0, end >= start, end <= frameCount else { throw ASRError("会议音频范围错误") }
        let reader = try FileHandle(forReadingFrom: directory.appendingPathComponent("audio.pcm"))
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(start * Self.frameBytes))
        let expected = (end - start) * Self.frameBytes
        let data = try reader.read(upToCount: expected) ?? Data()
        guard data.count == expected else { throw ASRError("会议音频读取不完整，已保留原文件") }
        return stride(from: 0, to: data.count, by: Self.frameBytes).map { offset in
            var frame = [Int16](repeating: 0, count: FrameConverter.frame)
            _ = frame.withUnsafeMutableBytes { data.copyBytes(to: $0, from: offset..<(offset + Self.frameBytes)) }
            return frame
        }
    }

    func save(_ record: MeetingRecord) throws {
        try audio.synchronize()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        try record.transcript.write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    func recover() throws -> MeetingRecord {
        var record = try JSONDecoder().decode(MeetingRecord.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        record.frameCount = frameCount
        record.captureEnded = true
        // Only completed, sealed ranges are trusted. Everything else can be replayed from disk.
        for i in record.segments.indices {
            let segment = record.segments[i]
            guard segment.startFrame >= 0, segment.endFrame >= segment.startFrame,
                  segment.endFrame <= frameCount else { throw ASRError("会议记录与音频不匹配") }
            if segment.state != .complete || !segment.sealed {
                record.segments[i].state = .pending
                record.segments[i].sealed = true
            }
        }
        // Includes frames written after the last manifest checkpoint, even after an app crash.
        var cursor = record.segments.last?.endFrame ?? 0
        while cursor < frameCount {
            let end = min(cursor + MeetingSegmenter.maximumFrames, frameCount)
            record.segments.append(MeetingSegment(id: record.segments.count, startFrame: cursor,
                                                  endFrame: end, sealed: true, hasSignal: true, state: .pending))
            cursor = end
        }
        return record
    }

    func exportWAV(to url: URL) throws {
        let size = frameCount * Self.frameBytes
        guard size <= Int(UInt32.max) - 36 else { throw ASRError("音频超过 WAV 大小限制，请使用会议目录中的 PCM 原文件") }
        var header = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of: &le) { header.append(contentsOf: $0) } }
        number(UInt32(36 + size)); header.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16000))
        number(UInt32(32000)); number(UInt16(2)); number(UInt16(16))
        header.append(Data("data".utf8)); number(UInt32(size))
        guard FileManager.default.createFile(atPath: url.path, contents: header) else { throw ASRError("无法导出音频") }
        let writer = try FileHandle(forWritingTo: url)
        let reader = try FileHandle(forReadingFrom: directory.appendingPathComponent("audio.pcm"))
        defer { try? writer.close(); try? reader.close() }
        try writer.seekToEnd()
        while let data = try reader.read(upToCount: 1 << 20), !data.isEmpty { try writer.write(contentsOf: data) }
    }
}

/// Prefer a pause after 5 seconds; hard-cap at 18 seconds for input-method ASR session limits.
/// Every frame belongs to exactly one segment, including silence and the final short tail.
struct MeetingSegmenter {
    static let maximumFrames = 900
    private(set) var count = 0
    private var quietFrames = 0

    mutating func push(level: Float) -> Bool {
        count += 1
        quietFrames = level < 0.12 ? quietFrames + 1 : 0
        return count >= Self.maximumFrames || (count >= 250 && quietFrames >= 25)
    }

    mutating func reset() { count = 0; quietFrames = 0 }
}
