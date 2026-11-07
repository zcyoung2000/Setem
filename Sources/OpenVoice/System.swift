import AppKit
import OSLog
import SwiftUI

enum DictationEvents { static let marker: Int64 = 0x564B_4559 }

/// 长按键：按住超过阈值开始、松开结束；发送模式会携带到定稿处理。点按快捷键：单个修饰键在阈值内松开，或组合键按下（吞掉不传给前台 App）
final class HotkeyMonitor {
    private static let log = Logger(subsystem: "do.j3.openvoice", category: "Hotkey")
    struct Configuration {
        let hold: Hotkey
        let send: Hotkey
        let tap: Shortcut?
    }
    private let configuration: () -> Configuration
    private let scheduleHold: (TimeInterval, @escaping () -> Void) -> Timer

    init(configuration: @escaping () -> Configuration = {
        Configuration(hold: .current, send: .sendHold, tap: .tap)
    }, scheduleHold: @escaping (TimeInterval, @escaping () -> Void) -> Timer = { delay, fire in
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in fire() }
    }) {
        self.configuration = configuration
        self.scheduleHold = scheduleHold
    }

    var onPress: () -> Void = {}
    /// A standalone tap modifier can skip pre-roll while a final is pending.
    /// Shared hold/tap keys still use onPress to preserve the start of a hold.
    var onTapPress: (() -> Void)?
    var onCancel: () -> Void = {}
    var onLongPress: (Bool) -> Void = { _ in }
    var onRelease: (Bool) -> Void = { _ in }
    var onTap: () -> Void = {}
    var onEscape: () -> Void = {}
    /// 设置里录制快捷键时暂停
    static var paused = false
    private static let threshold: TimeInterval = 0.3
    private enum HoldKind { case regular, send }
    private var tap: CFMachPort?
    private var downCode: Int64?
    private var swallowedCode: Int64?
    private var pressedAt = Date.distantPast
    private var cancelled = false
    private var active = false
    private var holdKind: HoldKind?
    private var timer: Timer?
    private var holdToken = 0

    /// 无权限时创建会失败，定时重试直到用户授权
    func start() {
        if install() { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.install() ?? true { t.invalidate() }
        }
    }

    private func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let swallow = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// 返回 true 表示吞掉该事件
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Delivery may have stopped before key-up. Re-enabling the tap alone
            // leaves pre-roll/holds alive and the next key-down looking repeated.
            let wasActive = active
            let sendsReturn = holdKind == .send
            holdToken += 1
            timer?.invalidate()
            timer = nil
            downCode = nil
            swallowedCode = nil
            active = false
            holdKind = nil
            cancelled = true
            Self.log.notice("event-tap-disabled type=\(type.rawValue) activeHold=\(wasActive)")
            // End a hold through the usual finalization path, preserving its tail
            // and final text. A manual tap recording keeps its explicit stop rule.
            if wasActive { onRelease(sendsReturn) }
            else { onCancel() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != DictationEvents.marker else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard !Self.paused else { return false }
        let config = configuration()
        let shortcut = config.tap
        let sendHold = config.send
        switch type {
        case .keyDown:
            if code == 53, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onEscape()
            }
            if let s = shortcut, !s.isModifier, code == s.keyCode,
               event.flags.intersection(Shortcut.mask).rawValue == s.modifiers {
                swallowedCode = code
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onTap() }
                return true
            }
            if downCode != nil, !active { cancelPending() }
        case .keyUp:
            if code == swallowedCode {
                swallowedCode = nil
                return true
            }
        case .flagsChanged:
            let hold = config.hold
            let sendCode = sendHold.keyCode
            let tapCode = shortcut.flatMap { $0.isModifier ? $0.keyCode : nil }
            guard code == downCode ?? code, code == hold.keyCode || code == sendCode || code == tapCode,
                  let flag = Shortcut.modifierFlag[code] else {
                if downCode != nil, !active { cancelPending() }
                return false
            }
            let pressed = event.flags.contains(flag)
            if pressed, downCode == nil {
                downCode = code
                let kind: HoldKind? = code == hold.keyCode ? .regular : code == sendCode ? .send : nil
                pressedAt = Date()
                cancelled = false
                if kind == nil, let onTapPress { onTapPress() }
                else { onPress() }
                if let kind { beginPendingHold(kind) }
            } else if !pressed, downCode != nil {
                downCode = nil
                holdToken += 1
                timer?.invalidate()
                if active {
                    active = false
                    let kind = holdKind
                    holdKind = nil
                    onRelease(kind == .send)
                } else if code == tapCode, !cancelled, Date().timeIntervalSince(pressedAt) < Self.threshold {
                    onTap()
                } else { onCancel() }
            }
        default: break
        }
        return false
    }

    private func beginPendingHold(_ kind: HoldKind) {
        cancelled = false
        holdKind = kind
        holdToken += 1
        let token = holdToken
        timer = scheduleHold(Self.threshold) { [weak self] in
            guard let self, self.holdToken == token, !self.cancelled,
                  self.downCode != nil else { return }
            self.active = true
            self.onLongPress(kind == .send)
        }
    }

    private func cancelPending() {
        holdToken += 1
        cancelled = true
        timer?.invalidate()
        timer = nil
        if !active { holdKind = nil }
        onCancel()
    }
}

enum TextInserter {
    /// 借剪贴板 + ⌘V 上屏，随后恢复原剪贴板
    static func insert(_ text: String, sendsReturn: Bool = false) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let change = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: isDown)
            e?.flags = .maskCommand
            e?.setIntegerValueField(.eventSourceUserData, value: DictationEvents.marker)
            e?.post(tap: .cghidEventTap)
        }
        if sendsReturn { pressReturn(after: 0.12) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pb.changeCount == change, !saved.isEmpty else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }

    /// Use a private source so modifiers still held by the user cannot turn this into a shortcut.
    static func pressReturn(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .privateState)
            for isDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: isDown) else { continue }
                e.flags = []
                e.setIntegerValueField(.eventSourceUserData, value: DictationEvents.marker)
                e.post(tap: .cghidEventTap)
            }
        }
    }
}

/// Liquid Glass is only available on macOS 26 and later; retain the old material on macOS 15.
struct LiquidGlassBackground<ShapeType: Shape>: ViewModifier {
    let shape: ShapeType
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    interactive ? Glass.regular.interactive() : .regular,
                    in: shape
                )
                .overlay {
                    // 玻璃穹顶微漫反射光泽（顶部微反光）
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.20),
                                Color.white.opacity(0.04),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
                }
                .overlay {
                    // 玻璃折射倒角与边缘高光（Specular Rim Highlight）
                    shape.stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.70), location: 0.0),
                                .init(color: Color.white.opacity(0.25), location: 0.35),
                                .init(color: Color.white.opacity(0.08), location: 0.70),
                                .init(color: Color.white.opacity(0.22), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                    .allowsHitTesting(false)
                }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                    .allowsHitTesting(false)
                }
        }
    }
}

extension View {
    func liquidGlassBackground<ShapeType: Shape>(
        in shape: ShapeType,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassBackground(shape: shape, interactive: interactive))
    }
}
