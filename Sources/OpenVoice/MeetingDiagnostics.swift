import AppKit
import Foundation

/// Reproducible native-window workload. No real microphone, credentials or meeting content.
@MainActor
func startMeetingBenchmark(panel: MeetingPanel, model: MeetingSession, directory: URL) {
    model.record.segments = (0..<1000).map { i in
        MeetingSegment(id: i, startFrame: i * 900, endFrame: (i + 1) * 900, sealed: true,
                       text: "这是性能测试用的会议记录。讨论需要完整保留，窗口应能流畅展开、收起和滚动。段落 \(i + 1)。",
                       provider: "测试渠道", state: .complete)
    }
    model.record.frameCount = 900000
    panel.show()
    var lastTick = ProcessInfo.processInfo.systemUptime
    var gaps: [Double] = []
    var toggleTimes: [Double] = []
    var sizes = Set<String>()
    var meterStep = 0
    var toggles = 0
    let started = lastTick
    let heartbeat = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        MainActor.assumeIsolated {
            let now = ProcessInfo.processInfo.systemUptime
            if now - started > 0.8 { gaps.append((now - lastTick) * 1000) }
            lastTick = now
            sizes.insert(NSStringFromSize(panel.frameForDiagnostics.size))
        }
    }
    let meter = Timer(timeInterval: 0.06, repeats: true) { _ in
        MainActor.assumeIsolated {
            meterStep += 1
            model.meter.push(Float(abs(sin(Double(meterStep) * 0.2))))
            if meterStep % 4 == 0 {
                var updated = model.record
                updated.frameCount += 12
                updated.segments[999].text = "持续更新的性能测试文字 \(meterStep)，不含真实会议内容。"
                model.apply(updated)
            }
        }
    }
    let toggle = Timer(timeInterval: 0.65, repeats: true) { _ in
        MainActor.assumeIsolated {
            let before = ProcessInfo.processInfo.systemUptime
            panel.toggle()
            panel.show()
            toggleTimes.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            toggles += 1
        }
    }
    for timer in [heartbeat, meter, toggle] { RunLoop.main.add(timer, forMode: .common) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        for timer in [heartbeat, meter, toggle] { timer.invalidate() }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        let report: [String: Any] = [
            "historySegments": 1000, "toggles": toggles,
            "heartbeatP95Milliseconds": percentile(gaps, 0.95),
            "heartbeatMaxMilliseconds": gaps.max() ?? 0,
            "toggleP95Milliseconds": percentile(toggleTimes, 0.95),
            "observedWindowSizes": sizes.count,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("benchmark.json"))
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
