import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol MeetingAudioCapture: AnyObject {
    func start() async throws -> AsyncThrowingStream<[Int16], Error>
    func stop() async
}

extension MeetingRecorder: MeetingAudioCapture {}

/// Only the tiny listening animation observes this object. Meter ticks must never
/// invalidate the transcript, scroll position, menu or entire window hierarchy.
@MainActor
final class MeetingMeter: ObservableObject {
    @Published private(set) var level: CGFloat = 0
    func push(_ raw: Float) {
        let value = CGFloat(raw)
        let next = value > level ? level * 0.25 + value * 0.75 : level * 0.8 + value * 0.2
        if abs(next - level) > 0.015 { level = next }
    }
    func reset() { if level != 0 { level = 0 } }
}

@MainActor
final class MeetingSession: ObservableObject {
    enum Phase { case idle, starting, restoring, recording, pausing, paused, stopping, stopped }
    @Published var phase = Phase.idle
    @Published var record = MeetingRecord(startedAt: Date())
    @Published var notice = ""
    @Published var expanded = false
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var directory: URL?
    let meter = MeetingMeter()
    var onDismiss: () -> Void = {}
    var onCaptureChanged: () -> Void = {}
    var canBeginCapture: () -> Bool = { true }

    private let captureFactory: () -> MeetingAudioCapture
    private let archiveRoot: URL
    private let engineFactory: MeetingPipeline.EngineFactory
    private let availableChannels: () -> [Channel]
    private var recorder: MeetingAudioCapture?
    private var pipeline: MeetingPipeline?
    private var work: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var generation = UUID()
    private var exiting = false
    private var pauseRequested = false
    private var interruption = ""
    private var appliedSequence: UInt64 = 0

    init(captureFactory: @escaping () -> MeetingAudioCapture = { MeetingRecorder() },
         archiveRoot: URL = MeetingArchive.root,
         engineFactory: @escaping MeetingPipeline.EngineFactory = MeetingPipeline.makeEngine,
         channels: @escaping () -> [Channel] = {
             let available = Channel.engines.filter { $0 != .offline || OfflineAssets.installed }
             let primary = Channel.current == .all ? Channel.doubao : Channel.current
             return ([primary] + available.filter { $0 != primary }).filter { available.contains($0) }
         }) {
        self.captureFactory = captureFactory
        self.archiveRoot = archiveRoot
        self.engineFactory = engineFactory
        availableChannels = channels
    }

    var isCapturing: Bool { exiting || [.starting, .restoring, .recording, .pausing, .stopping].contains(phase) }
    var hasOpenMeeting: Bool { phase == .paused || isCapturing }
    var pendingCount: Int { record.segments.filter { $0.state != .complete }.count }
    var provider: String { record.segments.last(where: { $0.state == .transcribing || $0.state == .retrying })?.provider ?? record.segments.last?.provider ?? "自动回退" }
    var status: String {
        switch phase {
        case .idle: return "会议转写"
        case .starting: return record.capturePaused == true ? "正在恢复收音" : "正在准备收音"
        case .restoring: return "正在恢复会议"
        case .recording: return record.segments.contains(where: { $0.state == .pending }) ? "持续录音 · 等待补转" : "正在聆听"
        case .pausing: return "正在保存尾音"
        case .paused: return "已暂停 · 未在收音"
        case .stopping: return "正在保存会议"
        case .stopped: return pendingCount > 0 ? "会议已结束 · 正在补转" : "会议已结束"
        }
    }

    static var latestDirectory: URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: MeetingArchive.root, includingPropertiesForKeys: nil)) ?? []
        return urls.filter {
            guard FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.json").path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: $0.appendingPathComponent("audio.pcm").path),
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.int64Value > 0
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    func start() {
        guard !hasOpenMeeting, permitCapture() else { return }
        generation = UUID()
        appliedSequence = 0
        let gen = generation
        pauseRequested = false
        interruption = ""
        phase = .starting
        meter.reset()
        notice = "首次使用需要麦克风和屏幕与系统音频录制权限。"
        record = MeetingRecord(startedAt: Date())
        expanded = false
        onCaptureChanged()
        let previous = pipeline
        pipeline = nil
        retryTimer?.cancel()
        work = Task {
            do {
                try await previous?.suspend()
                try Task.checkCancellation()
                let name = String(format: "%.0f", Date().timeIntervalSince1970 * 1000) + "-" + UUID().uuidString.prefix(8)
                let url = archiveRoot.appendingPathComponent(name, isDirectory: true)
                let archive = try await Task.detached { try MeetingArchive(directory: url) }.value
                directory = url
                pipeline = try makePipeline(archive: archive, record: record, gen: gen)
                await capture(resuming: false, gen: gen)
            } catch {
                notice = "无法开始会议：\(error.localizedDescription)"
                phase = .stopped
                expanded = true
                onCaptureChanged()
            }
        }
    }

    func pause() {
        guard phase == .recording else { return }
        pauseRequested = true
        phase = .pausing
        onCaptureChanged()
        let capture = recorder
        Task { await capture?.stop() }
    }

    func resume() {
        guard phase == .paused, pipeline != nil, permitCapture() else { return }
        phase = .starting
        interruption = ""
        notice = ""
        onCaptureChanged()
        let gen = generation
        work = Task { await capture(resuming: true, gen: gen) }
    }

    private func permitCapture() -> Bool {
        guard canBeginCapture() else {
            notice = "请先结束当前语音输入、渠道对比或快捷键设置，再开始会议收音。"
            return false
        }
        return true
    }

    private func capture(resuming: Bool, gen: UUID) async {
        guard let pipeline else { return }
        let capture = captureFactory()
        recorder = capture
        var captureError = ""
        do {
            let audio = try await capture.start()
            try Task.checkCancellation()
            if resuming { try await pipeline.resumeCapture() }
            pauseRequested = false
            phase = .recording
            notice = ""
            onCaptureChanged()
            startRetryTimer()
            let meter = self.meter
            // Audio ingestion and persistence run away from the UI executor. Main sees
            // at most 10 meter updates/s, independent of audio backlog and transcript size.
            let consumer = Task.detached {
                var lastMeter = ProcessInfo.processInfo.systemUptime
                for try await frame in audio {
                    try Task.checkCancellation()
                    try await pipeline.append(frame)
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastMeter >= 0.1 {
                        let level = Recorder.level(frame)
                        await meter.push(level)
                        lastMeter = now
                    }
                }
            }
            try await withTaskCancellationHandler { try await consumer.value } onCancel: { consumer.cancel() }
        } catch is CancellationError { }
        catch { captureError = error.localizedDescription; notice = captureError; expanded = true }
        await capture.stop()
        if !interruption.isEmpty { captureError = interruption }
        do {
            if !exiting {
                // Capture errors are resumable too; the user must explicitly restart acquisition.
                try await pipeline.pauseCapture(error: captureError)
            } else { try await pipeline.finishCapture(error: captureError) }
            apply(await pipeline.snapshot())
        } catch { notice = "保存会议失败：\(error.localizedDescription)"; expanded = true }
        guard generation == gen else { return }
        phase = exiting ? .stopped : .paused
        meter.reset()
        recorder = nil
        onCaptureChanged()
    }

    func interrupt(_ message: String) {
        guard isCapturing else { return }
        interruption = message
        notice = message
        expanded = true
        if phase == .starting { work?.cancel() } else { pause() }
    }

    func exit() {
        onDismiss()
        _ = beginShutdown()
    }

    func prepareForTermination() async {
        await beginShutdown().value
    }

    private func beginShutdown() -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        let wasStarting = phase == .starting
        let running = work
        let capture = recorder
        exiting = true
        phase = .stopping
        if wasStarting { running?.cancel() }
        let task = Task {
            if !wasStarting { await capture?.stop() }
            await running?.value
            retryTimer?.cancel()
            do {
                try await pipeline?.finishCapture(error: interruption)
                try await pipeline?.suspend()
                if let pipeline { apply(await pipeline.snapshot()) }
            } catch { notice = error.localizedDescription }
            phase = .stopped
            exiting = false
            shutdownTask = nil
            onCaptureChanged()
        }
        shutdownTask = task
        return task
    }

    func restoreLatest() {
        guard !hasOpenMeeting, let url = Self.latestDirectory else { return }
        let previous = pipeline
        retryTimer?.cancel()
        generation = UUID()
        appliedSequence = 0
        let gen = generation
        expanded = true
        notice = "正在恢复本地会议记录…"
        phase = .restoring
        onCaptureChanged()
        work = Task {
            do {
                try await previous?.suspend()
                let (archive, recovered) = try await Task.detached {
                    let archive = try MeetingArchive(directory: url)
                    return (archive, try archive.recover())
                }.value
                directory = url
                apply(recovered)
                pipeline = try makePipeline(archive: archive, record: recovered, gen: gen)
                notice = recovered.captureError
                startRetryTimer()
                await pipeline?.retryPending(force: true)
            } catch { notice = "恢复失败：\(error.localizedDescription)" }
            phase = .stopped
            onCaptureChanged()
        }
    }

    func apply(_ updated: MeetingRecord) {
        let sequence = updated.updateSequence ?? 0
        guard sequence >= appliedSequence else { return }
        appliedSequence = sequence
        if record.segments.count != updated.segments.count || zip(record.segments, updated.segments).contains(where: {
            $0.text != $1.text || $0.state != $1.state || $0.error != $1.error
        }) { transcriptRevision += 1 }
        record = updated
        if !updated.captureError.isEmpty { notice = updated.captureError }
    }

    func retry() { Task { await pipeline?.retryPending(force: true) } }
    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.transcript, forType: .string)
    }
    func revealFiles() { if let directory { NSWorkspace.shared.open(directory) } }

    func export(audio: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = audio ? [.wav] : [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "会议-\(record.startedAt.formatted(.iso8601.year().month().day()))" + (audio ? ".wav" : ".md")
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    if audio { try await self.pipeline?.exportWAV(to: url) }
                    else { try self.record.transcript.write(to: url, atomically: true, encoding: .utf8) }
                } catch { self.notice = "导出失败：\(error.localizedDescription)" }
            }
        }
    }

    private func makePipeline(archive: MeetingArchive, record: MeetingRecord, gen: UUID) throws -> MeetingPipeline {
        try MeetingPipeline(archive: archive, record: record, channels: availableChannels(), factory: engineFactory) { [weak self] record in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.apply(record)
            }
        }
    }

    private func startRetryTimer() {
        retryTimer?.cancel()
        retryTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                await self.pipeline?.retryPending()
            }
        }
    }
}
