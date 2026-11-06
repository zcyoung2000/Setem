import AppKit
import QuartzCore

/// Animate drawing attributes only. The complete, current transcript is always
/// available to accessibility and the dictation session without a typewriter delay.
final class DictationPreviewTextView: NSTextView {
    private struct Reveal {
        var range: NSRange
        let began: CFTimeInterval
    }
    private var reveals: [Reveal] = []
    private var revealTimer: Timer?

    func update(_ text: String, font: NSFont, animated: Bool) {
        self.font = font
        textColor = .labelColor
        guard string != text else {
            if !animated { finishReveals() }
            return
        }
        let old = Array(string), next = Array(text)
        var prefix = 0
        // Temporary attributes use UTF-16 offsets; canonically equivalent glyphs
        // with different encodings must be treated as a replacement as well.
        while prefix < min(old.count, next.count),
              String(old[prefix]).utf16.elementsEqual(String(next[prefix]).utf16) { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, next.count) - prefix,
              String(old[old.count - suffix - 1]).utf16.elementsEqual(String(next[next.count - suffix - 1]).utf16) { suffix += 1 }
        let prefixLength = String(next.prefix(prefix)).utf16.count
        let suffixLength = String(next.suffix(suffix)).utf16.count
        let oldLength = string.utf16.count, newLength = text.utf16.count
        let prefixRange = NSRange(location: 0, length: prefixLength)
        let suffixRange = NSRange(location: oldLength - suffixLength, length: suffixLength)
        var retained: [Reveal] = []
        if animated {
            for reveal in reveals {
                let head = NSIntersectionRange(reveal.range, prefixRange)
                if head.length > 0 { retained.append(Reveal(range: head, began: reveal.began)) }
                let tail = NSIntersectionRange(reveal.range, suffixRange)
                if tail.length > 0 {
                    retained.append(Reveal(range: NSRange(location: tail.location + newLength - oldLength, length: tail.length), began: reveal.began))
                }
            }
        }
        finishReveals()
        string = text
        setAccessibilityValue(text)
        guard animated, newLength > 0 else { return }
        reveals = retained
        let changed = NSRange(location: prefixLength, length: newLength - prefixLength - suffixLength)
        if changed.length > 0 { reveals.append(Reveal(range: changed, began: CACurrentMediaTime())) }
        paintReveals()
        guard !reveals.isEmpty else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.paintReveals() }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finishReveals() {
        revealTimer?.invalidate()
        revealTimer = nil
        reveals.removeAll()
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: string.utf16.count))
    }

    private func paintReveals() {
        let now = CACurrentMediaTime()
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: string.utf16.count))
        reveals.removeAll { now - $0.began >= 0.26 }
        for reveal in reveals {
            let progress = min(1, max(0, (now - reveal.began) / 0.26))
            let eased = progress * progress * (3 - 2 * progress)
            layoutManager?.addTemporaryAttribute(.foregroundColor,
                value: NSColor.labelColor.withAlphaComponent(0.16 + 0.84 * eased), forCharacterRange: reveal.range)
        }
        needsDisplay = true
        if reveals.isEmpty { revealTimer?.invalidate(); revealTimer = nil }
    }

    deinit { revealTimer?.invalidate() }
}
