import Foundation

/// Mirrors upstream controller.rs::Segments, including empty final semantics.
struct DictationTranscript {
    private struct Part {
        var text = ""
        var done = false
    }
    private var parts: [Part] = []
    private(set) var error: String?
    var text: String { parts.map(\.text).joined() }
    var finished: Bool { parts.allSatisfy(\.done) }

    mutating func begin() -> Int { parts.append(Part()); return parts.count - 1 }
    mutating func update(_ id: Int, text: String) -> Bool? {
        guard parts.indices.contains(id), !parts[id].done else { return nil }
        let changed = parts[id].text != text
        parts[id].text = text
        return changed
    }
    @discardableResult
    mutating func finish(_ id: Int, text: String, error: String?, keepPartial: Bool) -> Bool {
        guard parts.indices.contains(id), !parts[id].done else { return false }
        parts[id].done = true
        if let error { self.error = error }
        else if !text.isEmpty { parts[id].text = text }
        else if !keepPartial { parts[id].text = "" }
        return true
    }
}
