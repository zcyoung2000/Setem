import AppKit
import Combine
import QuartzCore
import SwiftUI

private let meetingMint = Color(red: 0.08, green: 0.52, blue: 0.44)
private let meetingInk = Color(red: 0.15, green: 0.20, blue: 0.25)

private final class MeetingFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A lightweight header follows the window. Keep the expensive transcript at a fixed
/// size and fade it in after the expansion starts, so neither text nor the icon reflows.
private final class MeetingSurface: NSView {
    let compact: NSHostingView<MeetingPanelView>
    let detail: NSHostingView<MeetingPanelView>
    var detailSize = NSSize(width: 480, height: 610)
    override var isFlipped: Bool { true }

    init(model: MeetingSession, toggle: @escaping () -> Void) {
        compact = NSHostingView(rootView: MeetingPanelView(model: model, expanded: false, toggle: toggle))
        detail = NSHostingView(rootView: MeetingPanelView(model: model, expanded: true, toggle: toggle))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(calibratedRed: 0.97, green: 0.985, blue: 0.98, alpha: 1).cgColor
        layer?.borderWidth = 0.8
        layer?.borderColor = NSColor(calibratedRed: 0.08, green: 0.52, blue: 0.44, alpha: 0.12).cgColor
        compact.sizingOptions = []
        detail.sizingOptions = []
        addSubview(detail)
        addSubview(compact)
        detail.alphaValue = 0
        detail.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        compact.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 82)
        detail.frame = NSRect(x: bounds.width - detailSize.width, y: 0, width: detailSize.width, height: detailSize.height)
    }
}

@MainActor
final class MeetingPanel {
    private let model: MeetingSession
    private let panel: NSPanel
    private var observer: Any?
    private var expansion: AnyCancellable?
    private var surface: MeetingSurface!
    private var transition = 0
    private var presentedExpanded = false

    init(model: MeetingSession) {
        self.model = model
        panel = MeetingFloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        surface = MeetingSurface(model: model, toggle: { [weak self] in self?.toggle() })
        panel.contentView = surface
        expansion = model.$expanded.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.layout(animated: true)
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func show() {
        if !panel.isVisible { layout() }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
    var frameForDiagnostics: NSRect { panel.frame }

    /// Render the actual native view for visual QA without microphone/network access.
    func savePreview(to url: URL) throws {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ASRError("无法渲染会议窗口") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ASRError("无法生成预览") }
        try data.write(to: url)
    }

    func toggle() {
        model.expanded.toggle()
    }

    func layout(animated: Bool = false) {
        let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        surface.detailSize = NSSize(width: min(480, bounds.width), height: min(610, bounds.height))
        let expanded = model.expanded
        let size = expanded ? surface.detailSize : NSSize(width: 292, height: 82)
        let topRight: NSPoint
        if panel.frame.isEmpty {
            let raw = UserDefaults.standard.string(forKey: "meetingPanelPosition")
            let saved = NSPointFromString(raw ?? "")
            let valid = raw != nil && NSScreen.screens.contains { $0.visibleFrame.contains(saved) }
            topRight = valid ? saved : NSPoint(x: bounds.maxX - 20, y: bounds.maxY - 40)
        } else { topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY) }
        let origin = NSPoint(x: min(max(topRight.x - size.width, bounds.minX), bounds.maxX - size.width),
                             y: min(max(topRight.y - size.height, bounds.minY), bounds.maxY - size.height))
        let target = NSRect(origin: origin, size: size)
        guard target != panel.frame || expanded != presentedExpanded else { return }
        presentedExpanded = expanded
        transition += 1
        let current = transition
        let shouldAnimate = animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        surface.detail.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shouldAnimate ? 0.32 : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.transition == current else { return }
                self.surface.detail.isHidden = !expanded
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shouldAnimate ? 0.32 : 0
            context.timingFunction = expanded ? CAMediaTimingFunction(controlPoints: 0.5, 0, 0.7, 1) : CAMediaTimingFunction(name: .easeOut)
            surface.detail.animator().alphaValue = expanded ? 1 : 0
        }
    }
}

/// Native mouse tracking distinguishes click from drag, without stealing text selection/buttons.
private struct MeetingDragArea: NSViewRepresentable {
    let click: () -> Void
    func makeNSView(context: Context) -> DragView { DragView(click: click) }
    func updateNSView(_ view: DragView, context: Context) { view.click = click }

    final class DragView: NSView {
        var click: () -> Void
        private var start: NSPoint = .zero
        private var windowOrigin: NSPoint = .zero
        private var dragged = false
        init(click: @escaping () -> Void) { self.click = click; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            windowOrigin = window?.frame.origin ?? .zero
            dragged = false
        }
        override func mouseDragged(with event: NSEvent) {
            let now = NSEvent.mouseLocation
            if hypot(now.x - start.x, now.y - start.y) > 4 { dragged = true }
            guard dragged, let window else { return }
            window.setFrameOrigin(NSPoint(x: windowOrigin.x + now.x - start.x, y: windowOrigin.y + now.y - start.y))
        }
        override func mouseUp(with event: NSEvent) {
            if dragged, let frame = window?.frame {
                UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.maxX, y: frame.maxY)), forKey: "meetingPanelPosition")
            } else { click() }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

private struct MeetingOrbit: View {
    @ObservedObject var meter: MeetingMeter
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { context in
            let t = active && !reduceMotion ? context.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                Circle().fill(meetingMint.opacity(0.10))
                Circle().strokeBorder(meetingMint.opacity(0.15), lineWidth: 1)
                Circle().trim(from: 0.05, to: 0.78)
                    .stroke(AngularGradient(colors: [meetingMint.opacity(0), meetingMint, .cyan, .purple.opacity(0.6)], center: .center), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 8) * 45))
                HStack(spacing: 3) {
                    ForEach(0..<5) { i in
                        let wave = CGFloat((sin(t * 5 + Double(i) * 1.3) + 1) / 2)
                        Capsule().fill(i == 4 ? .cyan : meetingMint)
                            .frame(width: 3, height: active ? 5 + (6 + meter.level * 20) * wave : 7)
                    }
                }
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityLabel(active ? "正在收音" : "收音已停止")
    }
}

struct MeetingPanelView: View {
    @ObservedObject var model: MeetingSession
    let expanded: Bool
    let toggle: () -> Void
    @State private var followLatest = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                Color.clear.frame(height: 82)
                Rectangle().fill(meetingInk.opacity(0.08)).frame(height: 1).padding(.horizontal, 20)
                expandedContent
            } else { header }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if expanded {
            RoundedRectangle(cornerRadius: 26).fill(Color(red: 0.97, green: 0.985, blue: 0.98))
            RoundedRectangle(cornerRadius: 26).fill(
                LinearGradient(colors: [.white.opacity(0.95), .clear, meetingMint.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay {
            if expanded {
                RoundedRectangle(cornerRadius: 26).strokeBorder(LinearGradient(colors: [.white, meetingInk.opacity(0.06), meetingMint.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
        }
        .foregroundStyle(meetingInk)
        .preferredColorScheme(.light)
        .onExitCommand { if model.expanded { toggle() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                MeetingOrbit(meter: model.meter, active: model.phase == .recording)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("会议转写").font(.system(size: 13, weight: .semibold))
                        if model.phase == .recording {
                            Text("LIVE").font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .tracking(1).foregroundStyle(meetingMint)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(meetingMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(meetingTimestamp(Double(model.record.frameCount) * 0.02))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(meetingMint)
                        Text(model.status).font(.system(size: 10)).foregroundStyle(meetingInk.opacity(0.65)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .overlay { MeetingDragArea(click: toggle).accessibilityLabel("拖动移动，点击展开或收起会议转写") }
            Button(action: toggle) {
                Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(meetingInk.opacity(0.55))
            .accessibilityLabel(model.expanded ? "收起会议转写" : "展开会议转写")
            .accessibilityIdentifier("meeting.expand")
            .help(model.expanded ? "收起窗口" : "展开转写内容")
        }
        .padding(.horizontal, 17)
        .frame(height: 82)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.and.mic").foregroundStyle(meetingMint)
                Text("麦克风 + 电脑声音")
                Spacer()
                Text(model.provider).lineLimit(1).foregroundStyle(meetingInk.opacity(0.6))
            }
            .font(.system(size: 10)).foregroundStyle(meetingInk.opacity(0.75))
            .padding(.horizontal, 22).padding(.vertical, 16)

            if !model.notice.isEmpty {
                Text(model.notice).font(.system(size: 11)).foregroundStyle(Color(red: 0.61, green: 0.33, blue: 0.06))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }

            if model.phase == .paused {
                Label("已暂停收音，点击恢复继续本场会议", systemImage: "pause.circle")
                    .font(.system(size: 11)).foregroundStyle(meetingMint)
                    .padding(.bottom, 12)
            }
            transcript

            VStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").foregroundStyle(meetingMint.opacity(0.8))
                    Text(model.pendingCount > 0 ? "音频已保留 · \(model.pendingCount) 段处理中" : "音频与转写已保存在本机")
                    Spacer()
                    if model.record.segments.contains(where: { $0.state == .pending }) {
                        Button("立即重试") { model.retry() }.foregroundStyle(meetingMint)
                    }
                }
                .font(.system(size: 10)).foregroundStyle(meetingInk.opacity(0.65))

                HStack(spacing: 10) {
                    if model.hasOpenMeeting {
                        Button { model.phase == .paused ? model.resume() : model.pause() } label: {
                            Label(model.phase == .paused ? "恢复转写" : model.phase == .pausing ? "正在暂停…" : model.phase == .starting ? "准备收音…" : "暂停转写",
                                  systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 112, height: 34)
                                .background(meetingMint.opacity(0.12), in: Capsule())
                                .foregroundStyle(meetingMint)
                        }
                        .disabled(model.phase != .recording && model.phase != .paused)
                        .accessibilityIdentifier("meeting.pauseResume")
                    }
                    Button { model.copyTranscript(); copied = true } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(model.record.segments.isEmpty)
                    Menu {
                        Button("导出转写文本…") { model.export(audio: false) }
                        Button("导出会议音频（WAV）…") { model.export(audio: true) }
                            .disabled(model.isCapturing)
                        Button("打开本地记录") { model.revealFiles() }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .menuStyle(.borderlessButton).fixedSize().help("导出会议记录")
                    Spacer(minLength: 0)
                    Button("退出") { model.exit() }.foregroundStyle(meetingInk.opacity(0.6))
                        .help("停止录音并关闭，保留会议记录和待补转音频")
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(meetingInk.opacity(0.85))
            }
            .padding(20)
            .background(meetingMint.opacity(0.035))
        }
        .onChange(of: model.transcriptRevision) { _, _ in copied = false }
    }

    private var transcript: some View {
        VStack(spacing: 8) {
            HStack {
                Text("实时转写").font(.system(size: 11, weight: .medium)).foregroundStyle(meetingInk.opacity(0.65))
                Spacer()
                Toggle("跟随最新", isOn: $followLatest).toggleStyle(.checkbox).controlSize(.mini)
                    .font(.system(size: 10)).foregroundStyle(meetingInk.opacity(0.65))
            }
            .padding(.horizontal, 22)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if model.record.segments.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: model.isCapturing ? "waveform" : "checkmark.circle")
                                    .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(meetingMint.opacity(0.7))
                                Text(model.isCapturing ? "让想法流动，让文字留下。" : "本次会议没有录入音频")
                                    .font(.system(size: 13)).foregroundStyle(meetingInk.opacity(0.65))
                                Text(model.phase == .paused ? "点击恢复，继续本场会议" : "收起窗口仍会持续录音与转写")
                                    .font(.system(size: 11)).foregroundStyle(meetingInk.opacity(0.55))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                        }
                        ForEach(model.record.segments) { segment in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(meetingTimestamp(segment.startTime)).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(meetingMint.opacity(0.65))
                                    if segment.state != .complete {
                                        Text(segment.state == .pending ? "等待补转" : segment.state == .retrying ? "切换渠道补转中" : "转写中")
                                            .font(.system(size: 9)).foregroundStyle(segment.state == .pending ? .orange : meetingInk.opacity(0.55))
                                    }
                                }
                                Text(segment.text.isEmpty ? (segment.state == .complete ? "（静音）" : model.phase == .recording ? "正在聆听并保留音频…" : "音频已保留，等待转写…") : segment.text)
                                    .font(.system(size: 14)).lineSpacing(6)
                                    .foregroundStyle(meetingInk.opacity(segment.state == .complete ? 0.95 : 0.7))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if !segment.error.isEmpty, segment.state != .complete {
                                    Text(segment.error).font(.system(size: 10)).foregroundStyle(.orange.opacity(0.7))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 15)
                }
                .onChange(of: model.transcriptRevision) { _, _ in
                    if followLatest && model.expanded {
                        proxy.scrollTo("latest", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
