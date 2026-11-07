import AppKit
import AVFoundation
import QuartzCore

/// Fixed, synthetic workloads; never opens a microphone, provider connection or user document.
@MainActor
func startPerformanceBenchmark(directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var report: [String: Any] = [:]
    let started = CACurrentMediaTime()
    let inbox = QwenInbox()
    for i in 0..<30_000 { await inbox.push(Data(repeating: UInt8(i % 251), count: 512)) }
    var packetChecksum = 0
    for _ in 0..<30_000 {
        let packet = try await inbox.read(timeout: 8)
        packetChecksum += Int(packet.first ?? 0)
    }
    report["packetQueueMilliseconds"] = (CACurrentMediaTime() - started) * 1000
    report["packetChecksum"] = packetChecksum
    report["packets"] = 30_000

    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    input.frameLength = 4096
    for i in 0..<4096 { input.floatChannelData![0][i] = Float(sin(Double(i) * 0.03) * 0.4) }
    let converter = try FrameConverter(from: format)
    var audioFrames = 0, audioChecksum: Int64 = 0
    let conversionStarted = CACurrentMediaTime()
    for _ in 0..<2000 {
        for frame in converter.push(input) {
            audioFrames += 1
            audioChecksum += frame.reduce(Int64(0)) { $0 + Int64($1) }
        }
    }
    if let tail = converter.flush() {
        audioFrames += 1
        audioChecksum += tail.reduce(Int64(0)) { $0 + Int64($1) }
    }
    report["conversionMilliseconds"] = (CACurrentMediaTime() - conversionStarted) * 1000
    report["audioFrames"] = audioFrames
    report["audioChecksum"] = audioChecksum

    let suite = "OpenVoice-Performance-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { throw ASRError("无法创建隔离的性能测试设置") }
    defaults.set(HUDStyle.standard.rawValue, forKey: "hudStyle")
    let hud = HUD(defaults: defaults, reduceMotion: { false })
    var text = String(repeating: "这是用于性能测试的合成文字，保留完整预览与动画。", count: 100)
    hud.show(text, listening: true)
    var durations: [Double] = [], gaps: [Double] = []
    var lastTick = CACurrentMediaTime(), updates = 0
    let heartbeat = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        let now = CACurrentMediaTime()
        if updates > 0 { gaps.append((now - lastTick) * 1000) }
        lastTick = now
    }
    RunLoop.main.add(heartbeat, forMode: .common)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let hudStarted = CACurrentMediaTime()
        let update = Timer(timeInterval: 0.04, repeats: true) { timer in
            updates += 1
            text += "第\(updates)段：新文字继续出现，完整保留 𠮷 😀。"
            let before = CACurrentMediaTime()
            hud.update(text)
            // Duplicate vendor packets must retain the animation already in progress.
            if updates % 5 == 0 { hud.update(text) }
            hud.level(Float(abs(sin(Double(updates) * 0.2))))
            durations.append((CACurrentMediaTime() - before) * 1000)
            guard updates >= 180 else { return }
            timer.invalidate()
            heartbeat.invalidate()
            report["hudWallSeconds"] = CACurrentMediaTime() - hudStarted
            report["hudUpdates"] = updates
            report["hudCharacters"] = text.count
            func percentile(_ values: [Double], _ fraction: Double) -> Double {
                let values = values.sorted()
                return values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count - 1) * fraction))]
            }
            report["hudUpdateP50Milliseconds"] = percentile(durations, 0.5)
            report["hudUpdateP95Milliseconds"] = percentile(durations, 0.95)
            report["heartbeatP95Milliseconds"] = percentile(gaps, 0.95)
            report["heartbeatMaxMilliseconds"] = gaps.max() ?? 0
            hud.showThinking()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                hud.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    defaults.removePersistentDomain(forName: suite)
                    do {
                        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        try data.write(to: directory.appendingPathComponent("benchmark.json"))
                        print(String(decoding: data, as: UTF8.self))
                        exit(0)
                    } catch { fputs("\(error)\n", stderr); exit(1) }
                }
            }
        }
        RunLoop.main.add(update, forMode: .common)
    }
}
