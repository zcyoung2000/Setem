import Foundation

/// Amortized constant-time removal; consumed payloads are released immediately.
struct FIFOBuffer<Element> {
    private var storage: [Element?] = []
    private var head = 0
    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func append(_ element: Element) { storage.append(element) }

    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        storage[head] = nil
        head += 1
        if head == storage.count {
            storage.removeAll(keepingCapacity: storage.capacity <= 128)
            head = 0
        } else if head >= 64, head >= storage.count / 2 {
            storage = Array(storage[head...])
            head = 0
        }
        return element
    }
}

/// Only a sub-frame tail is retained. Full incoming frames are copied directly
/// into their owned output, without shifting a growing intermediate PCM array.
struct AudioFrameBuffer {
    private var tail: [Int16] = []

    mutating func push(_ samples: UnsafeBufferPointer<Int16>) -> [[Int16]] {
        var frames: [[Int16]] = []
        frames.reserveCapacity((tail.count + samples.count) / FrameConverter.frame)
        var offset = 0
        while offset < samples.count {
            if tail.isEmpty, samples.count - offset >= FrameConverter.frame {
                frames.append(Array(samples[offset..<offset + FrameConverter.frame]))
                offset += FrameConverter.frame
            } else {
                tail.reserveCapacity(FrameConverter.frame)
                let count = min(FrameConverter.frame - tail.count, samples.count - offset)
                tail.append(contentsOf: samples[offset..<offset + count])
                offset += count
                if tail.count == FrameConverter.frame {
                    frames.append(tail)
                    tail = []
                }
            }
        }
        return frames
    }

    mutating func flush() -> [Int16]? {
        guard !tail.isEmpty else { return nil }
        var frame = tail
        tail = []
        frame.append(contentsOf: repeatElement(0, count: FrameConverter.frame - frame.count))
        return frame
    }
}

/// The owning serial queue resets one timer instead of accumulating delayed jobs.
final class ResettableIdleTimer {
    private let timer: DispatchSourceTimer

    init(queue: DispatchQueue, action: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler(handler: action)
        timer.schedule(deadline: .distantFuture)
        timer.resume()
    }

    func schedule(after delay: TimeInterval) { timer.schedule(deadline: .now() + delay) }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }
}
