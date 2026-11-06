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
        if textColor != .labelColor { textColor = .labelColor }
        let previous = string
        guard !previous.utf16.elementsEqual(text.utf16) else {
            if !animated { finishReveals() }
            return
        }
        guard animated, !text.isEmpty else {
            finishReveals()
            if let storage = textStorage {
                storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            } else { string = text }
            setAccessibilityValue(text)
            return
        }
        var oldStart = previous.startIndex, newStart = text.startIndex
        // Temporary attributes use UTF-16 offsets; canonically equivalent glyphs
        // with different encodings must be treated as a replacement as well.
        while oldStart < previous.endIndex, newStart < text.endIndex {
            let oldNext = previous.index(after: oldStart), newNext = text.index(after: newStart)
            guard previous[oldStart..<oldNext].utf16.elementsEqual(text[newStart..<newNext].utf16) else { break }
            oldStart = oldNext
            newStart = newNext
        }
        var oldEnd = previous.endIndex, newEnd = text.endIndex
        while oldEnd > oldStart, newEnd > newStart {
            let oldNext = previous.index(before: oldEnd), newNext = text.index(before: newEnd)
            guard previous[oldNext..<oldEnd].utf16.elementsEqual(text[newNext..<newEnd].utf16) else { break }
            oldEnd = oldNext
            newEnd = newNext
        }
        let prefixLength = text[..<newStart].utf16.count
        let suffixLength = text[newEnd...].utf16.count
        let oldLength = previous.utf16.count, newLength = text.utf16.count
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
        if let storage = textStorage {
            storage.replaceCharacters(in: NSRange(location: prefixLength, length: oldLength - prefixLength - suffixLength),
                with: NSAttributedString(string: String(text[newStart..<newEnd]), attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        } else { string = text }
        setAccessibilityValue(text)
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
        for reveal in reveals {
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: reveal.range)
            layoutManager?.invalidateDisplay(forCharacterRange: reveal.range)
        }
        reveals.removeAll()
    }

    private func paintReveals() {
        let now = CACurrentMediaTime()
        for reveal in reveals {
            if now - reveal.began >= 0.26 {
                layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: reveal.range)
                layoutManager?.invalidateDisplay(forCharacterRange: reveal.range)
                continue
            }
            let progress = min(1, max(0, (now - reveal.began) / 0.26))
            let eased = progress * progress * (3 - 2 * progress)
            layoutManager?.addTemporaryAttribute(.foregroundColor,
                value: NSColor.labelColor.withAlphaComponent(0.16 + 0.84 * eased), forCharacterRange: reveal.range)
            layoutManager?.invalidateDisplay(forCharacterRange: reveal.range)
        }
        reveals.removeAll { now - $0.began >= 0.26 }
        if reveals.isEmpty { revealTimer?.invalidate(); revealTimer = nil }
    }

    deinit { revealTimer?.invalidate() }
}
