import AppKit
import CHanbao
import SwiftUI

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--offline-worker" {
    // 离线识别子进程：stdin/stdout JSON-lines，由 OfflineWorker 拉起
    var argv: [UnsafeMutablePointer<CChar>?] = ["OpenVoice", "--pipe", args[2]].map { (s: String) in strdup(s) } + [nil]
    exit(hanbao_main(3, &argv))
}
signal(SIGPIPE, SIG_IGN) // 离线子进程退出后写管道不应杀死主进程

if let i = args.firstIndex(of: "--test"), i + 2 < args.count {
    // OpenVoice --test doubao|wetype|offline file.wav [--type]（--type：流式打到当前焦点输入框）
    let engine: ASREngine = switch args[i + 1] {
    case "wetype": WeTypeEngine()
    case "offline": OfflineEngine()
    case "qwen": QwenEngine()
    default: DoubaoEngine()
    }
    let url = URL(fileURLWithPath: args[i + 2])
    let typer = args.contains("--type") ? StreamTyper() : nil
    Task {
        do {
            let start = Date()
            let text = try await engine.run(audio: try fileFrames(url, realtime: true)) { partial in
                print("…", partial)
                DispatchQueue.main.async { typer?.update(partial) }
            }
            await MainActor.run { if !text.isEmpty { typer?.update(text) } }
            print("FINAL:", text, String(format: "(%.2fs)", Date().timeIntervalSince(start)))
            exit(0)
        } catch {
            print("ERROR:", error.localizedDescription)
            exit(1)
        }
    }
    RunLoop.main.run()
}

if args.contains("--preview-hud") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if args.contains("standard") {
            UserDefaults.standard.set(HUDStyle.standard.rawValue, forKey: "hudStyle")
        } else if args.contains("compact") {
            UserDefaults.standard.set(HUDStyle.compact.rawValue, forKey: "hudStyle")
        }
        let hud = HUD()
        hud.show("", listening: true)

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            step += 1
            let t = Float(step) * 0.08
            let lvl = abs(sin(t * 1.5)) * 0.45 + abs(cos(t * 2.3)) * 0.25
            hud.level(lvl)
        }

        let seconds = args.dropFirst().compactMap { Double($0) }.first ?? 6.0
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            exit(0)
        }
        app.run()
    }
}

if let i = args.firstIndex(of: "--preview-settings"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = MeetingSession()
        let window = SettingsWindow(meeting: model)
        if let index = args.firstIndex(of: "--settings-tab"), index + 1 < args.count,
           let tab = SettingsTab(rawValue: args[index + 1]) {
            window.navigation.tab = tab
        }
        window.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        let focused = args.contains("--focused")
        window.orderFrontRegardless()
        if focused {
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                var pending = window.contentView?.superview.map { [$0] } ?? []
                while let view = pending.popLast() {
                    if let tabs = view as? NSSegmentedControl, tabs.segmentCount == SettingsTab.allCases.count {
                        window.makeFirstResponder(tabs)
                        break
                    }
                    pending.append(contentsOf: view.subviews)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (focused ? 2 : 0.5)) {
            do {
                guard let view = window.contentView?.superview,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ASRError("无法渲染设置") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ASRError("无法生成设置预览") }
                try png.write(to: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}

if let i = args.firstIndex(of: "--preview-meeting"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = MeetingSession()
        model.phase = .recording
        model.meter.push(0.65)
        model.record.frameCount = 1850
        model.record.segments = [
            MeetingSegment(id: 0, startFrame: 0, endFrame: 900, sealed: true, text: "我们先对齐今天的会议目标。新版会保留每个人的想法，让讨论可以继续，记录也始终跟得上。", provider: "豆包输入法", state: .complete),
            MeetingSegment(id: 1, startFrame: 900, endFrame: 1700, sealed: true, text: "好的，我来补充一下时间安排。我们计划周五完成第一轮测试，下周一起收集反馈。", provider: "微信输入法", state: .complete),
            MeetingSegment(id: 2, startFrame: 1700, endFrame: 1850, text: "接下来，我们看看具体的实现方案……", provider: "微信输入法", state: .transcribing),
        ]
        let panel = MeetingPanel(model: model)
        if args.contains("--benchmark") {
            startMeetingBenchmark(panel: panel, model: model, directory: directory)
            app.run()
        }
        panel.show()
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                try panel.savePreview(to: directory.appendingPathComponent("meeting-compact.png"))
                panel.toggle()
                try await Task.sleep(for: .milliseconds(90))
                try panel.savePreview(to: directory.appendingPathComponent("meeting-transition.png"))
                try await Task.sleep(for: .milliseconds(400))
                try panel.savePreview(to: directory.appendingPathComponent("meeting-expanded.png"))
                model.phase = .paused
                try await Task.sleep(for: .milliseconds(120))
                try panel.savePreview(to: directory.appendingPathComponent("meeting-paused.png"))
                model.phase = .recording
                try await Task.sleep(for: .milliseconds(120))
                try panel.savePreview(to: directory.appendingPathComponent("meeting-resumed.png"))
                print("Meeting previews: \(directory.path)")
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
