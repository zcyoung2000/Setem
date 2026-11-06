import AppKit
import QuartzCore
import SwiftUI

private enum HUDPhase { case hidden, listening, thinking, message }

private final class HUDMeter: ObservableObject {
    @Published var level: CGFloat = 0
    func push(_ raw: Float) {
        let value = CGFloat(max(0, min(1, raw)))
        let next = value > level ? level * 0.3 + value * 0.7 : level * 0.85 + value * 0.15
        if next != level { level = next }
    }
}

/// A field of audio bars uses the whole available width, including during expansion.
private struct DictationAudioBars: View {
    @ObservedObject var meter: HUDMeter
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = max(12, Int(size.width / 6))
                let step = size.width / CGFloat(count)
                let gradient = Gradient(colors: [.cyan, .blue, .indigo, .purple])
                let shading = GraphicsContext.Shading.linearGradient(
                    gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                for index in 0..<count {
                    let position = CGFloat(index) / CGFloat(count - 1)
                    let envelope: CGFloat = 0.38 + 0.62 * pow(sin(CGFloat.pi * position), 0.7)
                    let pulse = CGFloat((sin(time * 5.2 + Double(index) * 0.68) + sin(time * 3.1 - Double(index) * 0.4) + 2) / 4)
                    let height = 3 + (size.height - 4) * envelope * (0.16 + meter.level * 0.84) * (0.35 + pulse * 0.65)
                    let rect = CGRect(x: CGFloat(index) * step + (step - 2.5) / 2,
                                      y: (size.height - height) / 2, width: 2.5, height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: shading)
                }
            }
        }
        .accessibilityLabel("正在录音")
    }
}

private struct DictationHUDBackdrop: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassBackground(in: RoundedRectangle(cornerRadius: 20))
    }
}

/// A soft spectral highlight travels across the full track without implying a percentage.
private final class DictationThinkingTrack: NSView {
    private let glow = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("dictation-thinking-progress")
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("thinking")
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
        glow.colors = [NSColor.systemCyan.withAlphaComponent(0).cgColor,
                       NSColor.systemCyan.withAlphaComponent(0.7).cgColor,
                       NSColor.systemBlue.withAlphaComponent(0.85).cgColor,
                       NSColor.systemPurple.withAlphaComponent(0.7).cgColor,
                       NSColor.systemPurple.withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        glow.locations = [0, 0.2, 0.5, 0.8, 1]
        layer?.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func animate(_ enabled: Bool) {
        if !enabled { glow.removeAnimation(forKey: "thinking-flow"); return }
        guard glow.animation(forKey: "thinking-flow") == nil else { return }
        let flow = CABasicAnimation(keyPath: "locations")
        flow.fromValue = [-0.7, -0.55, -0.4, -0.25, -0.1]
        flow.toValue = [1.1, 1.25, 1.4, 1.55, 1.7]
        flow.duration = 1.8
        flow.repeatCount = .infinity
        flow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(flow, forKey: "thinking-flow")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }
}

/// The label and track share a crossfade with the collapsing audio bars.
private final class DictationThinkingView: NSView {
    let label = NSTextField(labelWithString: "thinking")
    let progress = DictationThinkingTrack()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("dictation-thinking")
        label.identifier = NSUserInterfaceItemIdentifier("dictation-status-label")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        addSubview(progress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
        progress.frame = NSRect(x: 0, y: bounds.height - 7, width: bounds.width, height: 4)
    }
}

/// The glass and activity follow the live window size. The transcript keeps its
/// final wrap width and fades into the growing viewport, so words never stretch.
private final class DictationHUDSurface: NSView {
    let backdrop = NSHostingView(rootView: DictationHUDBackdrop())
    let audio: NSHostingView<DictationAudioBars>
    let thinking = DictationThinkingView()
    let preview = NSScrollView()
    let transcript = DictationPreviewTextView()
    let message = NSTextField(wrappingLabelWithString: "")
    private let meter: HUDMeter
    private var phase = HUDPhase.hidden
    private var previewSize = NSSize.zero
    private var textNeedsLayout = false
    private var inset: CGFloat = 16
    private var footerHeight: CGFloat = 32
    private var statusTimer: Timer?
    private var statusGeneration = 0
    private var thinkingMix: CGFloat = 0
    private(set) var text = ""
    private(set) var targetSize = NSSize.zero
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        let meter = HUDMeter()
        self.meter = meter
        audio = NSHostingView(rootView: DictationAudioBars(meter: meter, active: false))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 20
        backdrop.sizingOptions = []
        backdrop.identifier = NSUserInterfaceItemIdentifier("dictation-backdrop")
        audio.sizingOptions = []
        audio.identifier = NSUserInterfaceItemIdentifier("dictation-audio-bars")
        transcript.identifier = NSUserInterfaceItemIdentifier("dictation-preview-text")
        transcript.isEditable = false
        transcript.isSelectable = false
        transcript.drawsBackground = false
        transcript.textContainerInset = .zero
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.textContainer?.widthTracksTextView = true
        transcript.isHorizontallyResizable = false
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        preview.drawsBackground = false
        preview.documentView = transcript
        message.identifier = NSUserInterfaceItemIdentifier("dictation-status-label")
        message.font = .systemFont(ofSize: 13)
        message.maximumNumberOfLines = 2
        message.textColor = .labelColor
        for child in [backdrop, preview, audio, thinking, message] { addSubview(child) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ text: String, phase: HUDPhase, style: HUDStyle, screenWidth: CGFloat, reducedMotion: Bool) {
        let compact = style != .standard
        let font = NSFont.systemFont(ofSize: compact ? 14 : 15)
        let width = min(compact ? 360 : 440, screenWidth - 72)
        let changed = self.text != text
        let previous = self.phase
        if phase == .listening, previous == .hidden || previous == .message {
            meter.level = 0
        }
        self.text = text
        self.phase = phase
        inset = compact ? 16 : 20
        footerHeight = compact ? 32 : 40
        transcript.update(text, font: font, animated: !reducedMotion && (phase == .listening || phase == .thinking))
        let showsPreview = !text.isEmpty && (phase == .listening || phase == .thinking)
        let nextPreviewSize: NSSize
        if !showsPreview { nextPreviewSize = .zero }
        else if !changed, previewSize.width == width { nextPreviewSize = previewSize }
        else {
            let measured = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            nextPreviewSize = NSSize(width: width, height: min(160, max(22, ceil(measured.height) + 4)))
        }
        textNeedsLayout = textNeedsLayout || changed || previewSize != nextPreviewSize
        previewSize = nextPreviewSize
        if phase == .message {
            let bounds = (text as NSString).boundingRect(with: NSSize(width: width, height: 48),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
            targetSize = NSSize(width: max(160, min(width, ceil(bounds.width)) + inset * 2),
                                height: max(42, min(48, ceil(bounds.height)) + 24))
        } else {
            targetSize = NSSize(width: showsPreview ? width + inset * 2 : (compact ? 144 : 184),
                height: footerHeight + 24 + (showsPreview ? previewSize.height + 10 : 0))
        }
        preview.isHidden = !showsPreview
        message.isHidden = phase != .message
        message.stringValue = phase == .message ? text : ""
        thinking.progress.animate(phase == .thinking && !reducedMotion)
        if phase != previous || reducedMotion {
            transitionStatus(from: previous, to: phase, animated: !reducedMotion)
        }
        needsLayout = true
    }

    private func transitionStatus(from previous: HUDPhase, to phase: HUDPhase, animated: Bool) {
        statusGeneration += 1
        let generation = statusGeneration
        statusTimer?.invalidate()
        statusTimer = nil
        let destination: CGFloat = phase == .thinking ? 1 : 0
        let wasActive = previous == .listening || previous == .thinking
        let isActive = phase == .listening || phase == .thinking
        guard animated, wasActive, isActive, thinkingMix != destination else {
            thinkingMix = destination
            audio.isHidden = phase != .listening
            thinking.isHidden = phase != .thinking
            audio.alphaValue = 1 - destination
            thinking.alphaValue = destination
            audio.rootView = DictationAudioBars(meter: meter, active: phase == .listening)
            return
        }
        audio.isHidden = false
        thinking.isHidden = false
        audio.rootView = DictationAudioBars(meter: meter, active: true)
        let start = thinkingMix
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.statusGeneration == generation else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - began) / 0.3)
            let eased = CGFloat(progress * progress * (3 - 2 * progress))
            self.thinkingMix = start + (destination - start) * eased
            self.audio.alphaValue = 1 - self.thinkingMix
            self.thinking.alphaValue = self.thinkingMix
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            if progress >= 1 {
                timer.invalidate()
                self.statusTimer = nil
                self.audio.isHidden = phase != .listening
                self.thinking.isHidden = phase != .thinking
                self.audio.rootView = DictationAudioBars(meter: self.meter, active: phase == .listening)
            }
        }
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { statusTimer?.invalidate() }

    func level(_ value: Float) { meter.push(value) }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        let footer = NSRect(x: inset, y: bounds.height - 12 - footerHeight,
                            width: max(1, bounds.width - inset * 2), height: footerHeight)
        let audioHeight = footer.height + (6 - footer.height) * thinkingMix
        audio.frame = NSRect(x: footer.minX, y: footer.minY + (footer.height - audioHeight), width: footer.width, height: audioHeight)
        thinking.frame = footer
        message.frame = bounds.insetBy(dx: inset, dy: 12)
        if !preview.isHidden {
            let availableHeight = max(0, footer.minY - 22)
            preview.frame = NSRect(x: (bounds.width - previewSize.width) / 2,
                y: 12, width: previewSize.width, height: min(previewSize.height, availableHeight))
            preview.alphaValue = min(1, max(0, (bounds.height - footerHeight - 34) / min(previewSize.height, 36)))
            if textNeedsLayout, let container = transcript.textContainer, let manager = transcript.layoutManager {
                container.containerSize = NSSize(width: previewSize.width, height: .greatestFiniteMagnitude)
                manager.ensureLayout(for: container)
                transcript.setFrameSize(NSSize(width: previewSize.width,
                    height: max(previewSize.height, ceil(manager.usedRect(for: container).height) + 4)))
                textNeedsLayout = false
            }
            // AppKit can retain a shifted document origin as the viewport resizes.
            // Keep the document anchored and reapply the intended scroll position
            // on each layout, including status changes that reuse the same text.
            transcript.setFrameOrigin(.zero)
            let offset = transcript.bounds.height > 160
                ? max(0, transcript.bounds.height - preview.contentView.bounds.height) : 0
            preview.contentView.scroll(to: NSPoint(x: 0, y: offset))
            preview.reflectScrolledClipView(preview.contentView)
        }
    }
}

/// NSView's bounds transform scales the complete, already laid-out content for
/// entrance/exit, while ordinary text growth continues to use normal layout.
private final class DictationHUDContainer: NSView {
    let surface: DictationHUDSurface
    var renderedSize: NSSize?

    init(surface: DictationHUDSurface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizesSubviews = false
        surface.autoresizesSubviews = false
        surface.identifier = NSUserInterfaceItemIdentifier("dictation-surface")
        addSubview(surface)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        layer?.cornerRadius = min(20, bounds.width / 2, bounds.height / 2)
        surface.frame = bounds
        surface.bounds = NSRect(origin: .zero, size: renderedSize ?? bounds.size)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
    }
}

/// A non-activating panel that opens from and closes into a small point.
final class HUD {
    private let panel: NSPanel
    private let surface = DictationHUDSurface()
    private lazy var container = DictationHUDContainer(surface: surface)
    private let defaults: UserDefaults
    private let reduceMotion: () -> Bool
    private var phase = HUDPhase.hidden
    private var resizeTimer: Timer?
    private var resizeGeneration = 0
    private var dismissTimer: Timer?
    private var dismissGeneration = 0
    private var targetFrame: NSRect?
    private var hideWork: DispatchWorkItem?
    private var visibilityGeneration = 0
    private var observer: Any?
    var isVisible: Bool { panel.isVisible }
    var windowForDiagnostics: NSWindow { panel }

    init(defaults: UserDefaults = .standard,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.defaults = defaults
        self.reduceMotion = reduceMotion
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible, self.phase != .hidden else { return }
            self.layout()
        }
    }

    deinit {
        resizeTimer?.invalidate()
        dismissTimer?.invalidate()
        hideWork?.cancel()
        panel.orderOut(nil)
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func show(_ text: String, listening: Bool) { present(text, phase: listening ? .listening : .message) }

    func showThinking() {
        present(phase == .listening || phase == .thinking ? surface.text : "", phase: .thinking)
    }

    private func present(_ text: String, phase: HUDPhase) {
        let entering = !isVisible || self.phase == .hidden
        hideWork?.cancel()
        visibilityGeneration += 1
        dismissGeneration += 1
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.alphaValue = 1
        self.phase = phase
        layout(text: text, opening: entering)
        panel.orderFrontRegardless()
    }

    func level(_ value: Float) {
        guard phase == .listening else { return }
        surface.level(value)
    }

    func update(_ text: String) {
        guard isVisible, phase == .listening || phase == .thinking else { return }
        layout(text: text)
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        hideWork = nil
        visibilityGeneration += 1
        guard delay > 0 else { close(); return }
        let generation = visibilityGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.close()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func close() {
        resizeGeneration += 1
        resizeTimer?.invalidate()
        resizeTimer = nil
        targetFrame = nil
        phase = .hidden
        // Recognition ownership ends immediately. The last rendered content scales
        // into a point without delaying final insertion or accepting late callbacks.
        guard isVisible, !reduceMotion() else { finishClose(); return }
        guard dismissTimer == nil else { return }
        dismissGeneration += 1
        let generation = dismissGeneration
        let began = CACurrentMediaTime()
        let start = panel.frame
        let destination = pointFrame(in: start)
        container.renderedSize = container.renderedSize ?? start.size
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.dismissGeneration == generation else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - began) / 0.34)
            let eased = CGFloat(progress * progress * (3 - 2 * progress))
            self.panel.setFrame(self.interpolate(start, destination, width: eased, height: eased), display: true)
            self.layoutContainer()
            if progress >= 1 { self.finishClose() }
        }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishClose() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        container.renderedSize = nil
        surface.configure("", phase: .hidden, style: .compact, screenWidth: 800, reducedMotion: true)
    }

    private func pointFrame(in frame: NSRect) -> NSRect {
        NSRect(x: frame.midX - 4, y: frame.midY - 4, width: 8, height: 8)
    }

    private func interpolate(_ start: NSRect, _ end: NSRect, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: start.minX + (end.minX - start.minX) * width,
               y: start.minY + (end.minY - start.minY) * height,
               width: start.width + (end.width - start.width) * width,
               height: start.height + (end.height - start.height) * height)
    }

    private func layoutContainer() {
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }

    private func layout(text: String? = nil, opening: Bool = false) {
        let screen = (isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let style = HUDStyle(rawValue: defaults.string(forKey: "hudStyle") ?? "") ?? .compact
        surface.configure(text ?? surface.text, phase: phase, style: style, screenWidth: bounds.width, reducedMotion: reduceMotion())
        let size = surface.targetSize
        let target = NSRect(x: bounds.midX - size.width / 2, y: bounds.minY + 80, width: size.width, height: size.height)
        guard target != targetFrame || opening else { layoutContainer(); return }
        let scaling = opening || container.renderedSize != nil
        targetFrame = target
        resizeGeneration += 1
        let generation = resizeGeneration
        resizeTimer?.invalidate()
        resizeTimer = nil
        guard !reduceMotion() else {
            container.renderedSize = nil
            panel.setFrame(target, display: true)
            layoutContainer()
            return
        }
        if scaling {
            container.renderedSize = target.size
            if !isVisible { panel.setFrame(pointFrame(in: target), display: true) }
        }
        let start = panel.frame
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.resizeGeneration == generation else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - began
            let progress = min(1, elapsed / (scaling ? 0.32 : 0.36))
            let eased = CGFloat(1 - pow(1 - progress, 4))
            let heightProgress = scaling ? progress : min(1, elapsed / 0.44)
            let heightEase = scaling ? eased : CGFloat(heightProgress * heightProgress * (3 - 2 * heightProgress))
            let frame = self.interpolate(start, target, width: eased, height: heightEase)
            self.panel.setFrame(frame, display: true)
            if progress >= 1, heightProgress >= 1 {
                timer.invalidate()
                self.resizeTimer = nil
                self.container.renderedSize = nil
            }
            self.layoutContainer()
        }
        resizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        layoutContainer()
    }
}
