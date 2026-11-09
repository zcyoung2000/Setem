import Foundation

/// Opt-in local evidence for missing-text reports: the exact 16kHz frames handed to
/// recognition, plus raw and final text, so a lost word can be traced to the audio or
/// to recognition/polishing. Off by default; nothing is uploaded and only the newest
/// recordings are kept. Enable: `defaults write do.j3.openvoice debugAudioCapture -bool true`.
enum DebugCapture {
    static let key = "debugAudioCapture"
    private static let keep = 30
    private static let lock = NSLock()
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    static var directory: URL { appSupportDirectory().appendingPathComponent("Debug", isDirectory: true) }

    static func makeName() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return format.string(from: Date())
    }

    /// Forwards every frame unchanged and writes the WAV once the source ends.
    static func tee(_ audio: AsyncStream<[Int16]>, name: String) -> AsyncStream<[Int16]> {
        AsyncStream { output in
            let task = Task {
                var samples: [Int16] = []
                for await frame in audio {
                    samples += frame
                    output.yield(frame)
                }
                output.finish()
                write(samples, name: name)
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    static func note(_ line: String) {
        lock.withLock {
            let url = directory.appendingPathComponent("texts.log")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entry = Data("\(makeName()) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
            } else {
                try? entry.write(to: url)
            }
        }
    }

    private static func write(_ samples: [Int16], name: String) {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        lock.withLock {
            let manager = FileManager.default
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(name + ".wav"))
            let old = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".wav") }.sorted().dropLast(keep)
            old.forEach { try? manager.removeItem(at: directory.appendingPathComponent($0)) }
        }
    }
}
