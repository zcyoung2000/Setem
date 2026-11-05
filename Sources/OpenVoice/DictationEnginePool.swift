import Foundation

/// An idle client may be warmed/reused, but a leased client belongs to one recording.
@MainActor
final class DictationEnginePool {
    struct Lease {
        let engine: ASREngine
        fileprivate let preparation: Task<Void, Never>?
        func ready() async { await preparation?.value }
    }
    private final class Entry {
        let engine: ASREngine
        var preparation: Task<Void, Never>?
        init(_ engine: ASREngine) { self.engine = engine }
    }
    private let factory: (Channel) -> ASREngine
    private var idle: [Channel: Entry] = [:]

    init(factory: @escaping (Channel) -> ASREngine = DictationSession.makeEngine) { self.factory = factory }
    func prewarm(_ channel: Channel) {
        let entry = idle[channel] ?? Entry(factory(channel))
        idle[channel] = entry
        guard entry.preparation == nil else { return }
        let engine = entry.engine
        entry.preparation = Task { [weak entry] in
            await engine.prepare()
            entry?.preparation = nil
        }
    }
    func take(_ channel: Channel) -> Lease {
        let entry = idle.removeValue(forKey: channel) ?? Entry(factory(channel))
        return Lease(engine: entry.engine, preparation: entry.preparation)
    }
    func reuse(_ engine: ASREngine, channel: Channel) {
        // Keep at most one idle client per channel; another active recording may
        // already have returned a client. Dropping an extra closes its resources.
        if idle[channel] == nil { idle[channel] = Entry(engine) }
    }
}
