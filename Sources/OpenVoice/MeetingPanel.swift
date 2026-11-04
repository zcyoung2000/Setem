import AppKit
import Combine
import QuartzCore
import SwiftUI

private let meetingBlue = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(red: 0.35, green: 0.68, blue: 1.0, alpha: 1)
        : NSColor(red: 0.04, green: 0.48, blue: 0.96, alpha: 1)
}))

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
        layer?.backgroundColor = .clear

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

    override func mouseDown(with event: NSEvent) {
        if let window {
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
final class MeetingPanel {
    private let model: MeetingSession
    private let panel: NSPanel
    private var observer: Any?
    private var moveObserver: Any?
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
        panel.isMovableByWindowBackground = true
        surface = MeetingSurface(model: model, toggle: { [weak self] in self?.toggle() })
        panel.contentView = surface
        expansion = model.$expanded.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.layout(animated: true)
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, let frame = self.panel.frame as NSRect? else { return }
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.maxX, y: frame.maxY)), forKey: "meetingPanelPosition")
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

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
    var onClick: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var canClick: Bool = false

    func makeNSView(context: Context) -> DragView {
        DragView(onClick: onClick, onDoubleClick: onDoubleClick, canClick: canClick)
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.canClick = canClick
    }

    final class DragView: NSView {
        var onClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var canClick: Bool

        init(onClick: (() -> Void)?, onDoubleClick: (() -> Void)?, canClick: Bool) {
            self.onClick = onClick
            self.onDoubleClick = onDoubleClick
            self.canClick = canClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            guard let window else { return }
            let initialOrigin = window.frame.origin
            window.performDrag(with: event)
            let finalOrigin = window.frame.origin

            if hypot(finalOrigin.x - initialOrigin.x, finalOrigin.y - initialOrigin.y) > 2 {
                let frame = window.frame
                UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.maxX, y: frame.maxY)), forKey: "meetingPanelPosition")
            } else if canClick {
                onClick?()
            }
        }
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
                Circle().fill(meetingBlue.opacity(0.12))
                Circle().strokeBorder(meetingBlue.opacity(0.20), lineWidth: 1)
                Circle().trim(from: 0.05, to: 0.78)
                    .stroke(
                        AngularGradient(
                            colors: [meetingBlue.opacity(0), meetingBlue, .cyan, meetingBlue.opacity(0.8)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 8) * 45))
                HStack(spacing: 3) {
                    ForEach(0..<5) { i in
                        let wave = CGFloat((sin(t * 5 + Double(i) * 1.3) + 1) / 2)
                        Capsule().fill(i == 4 ? .cyan : meetingBlue)
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
                Divider().opacity(0.25).padding(.horizontal, 20)
                expandedContent
            } else {
                header
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if expanded || !model.expanded {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if expanded || !model.expanded {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
            }
        }
        .foregroundStyle(Color.primary)
        .onExitCommand { if model.expanded { toggle() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MeetingOrbit(meter: model.meter, active: model.phase == .recording)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("会议转写")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    if model.phase == .recording {
                        HStack(spacing: 3.5) {
                            Circle().fill(meetingBlue).frame(width: 5, height: 5)
                            Text("LIVE")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .tracking(0.8)
                        }
                        .foregroundStyle(meetingBlue)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(meetingBlue.opacity(0.12), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(meetingTimestamp(Double(model.record.frameCount) * 0.02))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(meetingBlue)
                    Text(model.status)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: toggle) {
                Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .liquidGlassBackground(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .accessibilityLabel(model.expanded ? "收起会议转写" : "展开会议转写")
            .accessibilityIdentifier("meeting.expand")
            .help(model.expanded ? "收起窗口" : "展开转写内容")
        }
        .padding(.horizontal, 18)
        .frame(height: 82)
        .contentShape(Rectangle())
        .background {
            MeetingDragArea(
                onClick: { if !model.expanded { toggle() } },
                onDoubleClick: { if model.expanded { toggle() } },
                canClick: !model.expanded
            )
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            subheader

            if !model.notice.isEmpty {
                Text(model.notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.50, blue: 0.15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.orange.opacity(0.20), lineWidth: 0.8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            if model.phase == .paused {
                Label("已暂停收音，点击恢复继续本场会议", systemImage: "pause.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(meetingBlue)
                    .padding(.bottom, 10)
            }

            transcript
            footer
        }
        .onChange(of: model.transcriptRevision) { _, _ in copied = false }
    }

    private var subheader: some View {
        HStack(spacing: 6) {
            Label("麦克风 + 电脑声音", systemImage: "waveform.and.mic")
                .foregroundStyle(Color.secondary)
            Spacer()
            Text(model.provider)
                .lineLimit(1)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .font(.system(size: 11))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background {
            MeetingDragArea(canClick: false)
        }
    }

    private var transcript: some View {
        VStack(spacing: 8) {
            HStack {
                Text("实时转写")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button {
                    followLatest.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: followLatest ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                            .font(.system(size: 10, weight: .semibold))
                        Text("跟随最新")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(followLatest ? meetingBlue : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(followLatest ? meetingBlue.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                    .liquidGlassBackground(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
            }
            .padding(.horizontal, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.record.segments.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: model.isCapturing ? "waveform" : "checkmark.circle")
                                    .font(.system(size: 30, weight: .ultraLight))
                                    .foregroundStyle(meetingBlue.opacity(0.8))
                                Text(model.isCapturing ? "让想法流动，让文字留下。" : "本次会议没有录入音频")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.primary.opacity(0.75))
                                Text(model.phase == .paused ? (model.record.captureEnded == true ? "点击继续转写，继续本场会议" : "点击恢复，继续本场会议") : "收起窗口仍会持续录音与转写")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 70)
                        }

                        ForEach(model.record.segments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(meetingTimestamp(segment.startTime))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(meetingBlue)
                                    if segment.state != .complete {
                                        Text(segment.state == .pending ? "等待补转" : segment.state == .retrying ? "切换渠道补转中" : "转写中")
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundStyle(segment.state == .pending ? Color.orange : Color.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(
                                                (segment.state == .pending ? Color.orange : Color.primary).opacity(0.08),
                                                in: Capsule()
                                            )
                                    }
                                }
                                Text(segment.text.isEmpty ? (segment.state == .complete ? "（静音）" : model.phase == .recording ? "正在聆听并保留音频…" : "音频已保留，等待转写…") : segment.text)
                                    .font(.system(size: 13.5))
                                    .lineSpacing(5)
                                    .foregroundStyle(Color.primary.opacity(segment.state == .complete ? 0.95 : 0.65))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !segment.error.isEmpty, segment.state != .complete {
                                    Label(segment.error, systemImage: "exclamationmark.triangle")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Color.orange)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(12)
                            .background(
                                Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.visible)
                .background {
                    MeetingDragArea(canClick: false)
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

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(meetingBlue)
                Text(model.pendingCount > 0 ? "音频已保留 · \(model.pendingCount) 段处理中" : "音频与转写已保存在本机")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary)
                Spacer()
                if model.record.segments.contains(where: { $0.state == .pending }) {
                    Button("立即重试") {
                        model.retry()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(meetingBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(meetingBlue.opacity(0.12), in: Capsule())
                    .liquidGlassBackground(in: Capsule(), interactive: true)
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                }
            }

            HStack(spacing: 10) {
                if model.hasOpenMeeting {
                    Button {
                        model.phase == .paused ? model.resume() : model.pause()
                    } label: {
                        Label(
                            model.phase == .paused ? (model.record.captureEnded == true ? "继续转写" : "恢复转写") : model.phase == .pausing ? "正在暂停…" : model.phase == .starting ? "准备收音…" : "暂停转写",
                            systemImage: model.phase == .paused ? "play.fill" : "pause.fill"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(meetingBlue, in: Capsule())
                        .liquidGlassBackground(in: Capsule(), interactive: true)
                        .shadow(color: meetingBlue.opacity(0.3), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.phase != .recording && model.phase != .paused)
                    .accessibilityIdentifier("meeting.pauseResume")
                    .focusable(false)
                    .focusEffectDisabled()
                }

                Button {
                    model.copyTranscript()
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .liquidGlassBackground(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(model.record.segments.isEmpty)
                .focusable(false)
                .focusEffectDisabled()

                Menu {
                    Button("导出转写文本…") { model.export(audio: false) }
                    Button("导出会议音频（WAV）…") { model.export(audio: true) }
                        .disabled(model.isCapturing)
                    Divider()
                    Button("打开本地记录") { model.revealFiles() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.06), in: Circle())
                        .liquidGlassBackground(in: Circle(), interactive: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("导出会议记录")
                .focusable(false)
                .focusEffectDisabled()

                Spacer(minLength: 0)

                Button {
                    model.exit()
                } label: {
                    Text("退出")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .liquidGlassBackground(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .help("停止录音并关闭，保留会议记录和待补转音频")
                .focusable(false)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            Color.primary.opacity(0.02)
                .overlay {
                    MeetingDragArea(canClick: false)
                }
        }
    }
}
