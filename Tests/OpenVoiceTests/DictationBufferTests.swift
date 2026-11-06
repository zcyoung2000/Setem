import AppKit
import AVFoundation
import XCTest
@testable import OpenVoice

final class DictationBufferTests: XCTestCase {
    func testFIFOOrderingAcrossCompactionAndIndependentCopies() {
        var queue = FIFOBuffer<Int>()
        for value in 0..<10_000 { queue.append(value) }
        for value in 0..<8000 { XCTAssertEqual(queue.popFirst(), value) }
        for value in 10_000..<11_000 { queue.append(value) }
        var copy = queue
        for value in 8000..<11_000 {
            XCTAssertEqual(queue.popFirst(), value)
            XCTAssertEqual(copy.popFirst(), value)
        }
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.popFirst())
        queue.append(42)
        XCTAssertEqual(queue.popFirst(), 42)
    }

    func testFIFOReleasesConsumedPayloadWhileLaterPacketsRemain() {
        final class Payload {}
        var queue = FIFOBuffer<Payload>()
        var first: Payload? = Payload()
        weak var released = first
        queue.append(first!)
        queue.append(Payload())
        first = nil
        XCTAssertNotNil(released)
        _ = queue.popFirst()
        XCTAssertNil(released, "A slice into an old backing array must not retain consumed audio/network data")
        XCTAssertEqual(queue.count, 1)
    }

    func testPCMFramingPreservesEverySampleAndPadsOnlyTheFinalTail() {
        var buffer = AudioFrameBuffer()
        let samples = (0..<4099).map { Int16($0) }
        var output: [[Int16]] = [], cursor = 0
        for size in [1, 319, 321, 17, 2048, 4, 1200, 189] {
            let end = min(samples.count, cursor + size)
            let chunk = Array(samples[cursor..<end])
            output += chunk.withUnsafeBufferPointer { buffer.push($0) }
            cursor = end
        }
        XCTAssertEqual(cursor, samples.count)
        XCTAssertTrue(output.allSatisfy { $0.count == 320 })
        let firstFrame = output[0]
        if let tail = buffer.flush() { output.append(tail) }
        XCTAssertEqual(output.flatMap { $0 }, samples + [Int16](repeating: 0, count: 61))
        XCTAssertNil(buffer.flush())
        let next = [Int16](repeating: -100, count: 320)
        XCTAssertEqual(next.withUnsafeBufferPointer { buffer.push($0) }, [next])
        XCTAssertEqual(firstFrame, Array(samples.prefix(320)), "Later callbacks must not overwrite delivered PCM")
    }

    func testReusableConverterMatchesNativeFreshBuffersAcrossChangingInputSizes() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let actual = try FrameConverter(from: format)
        let reference = try XCTUnwrap(AVAudioConverter(from: format, to: FrameConverter.format))
        var expected: [Int16] = [], output: [Int16] = [], cursor = 0
        for size in Array(repeating: [480, 96, 4096, 240, 1024, 1, 8192, 64], count: 10).flatMap({ $0 }) {
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(size)))
            input.frameLength = AVAudioFrameCount(size)
            for i in 0..<size { input.floatChannelData![0][i] = Float(sin(Double(cursor + i) * 0.03) * 0.4) }
            cursor += size
            output += actual.push(input).flatMap { $0 }
            let fresh = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: FrameConverter.format,
                frameCapacity: AVAudioFrameCount(Double(size) / 3) + 64))
            var fed = false
            _ = reference.convert(to: fresh, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            expected.append(contentsOf: UnsafeBufferPointer(start: fresh.int16ChannelData![0], count: Int(fresh.frameLength)))
        }
        if let tail = actual.flush() { output += tail }
        expected += repeatElement(Int16(0), count: (320 - expected.count % 320) % 320)
        XCTAssertEqual(output, expected, "Output reuse must preserve native resampling and exact sample order")
        XCTAssertNil(actual.flush())
    }

    func testIdleDeadlineCanBeResetRepeatedlyWithoutRepeatedFiring() async throws {
        let queue = DispatchQueue(label: "openvoice.tests.idle")
        let fired = expectation(description: "Latest idle deadline")
        let lock = NSLock()
        var count = 0
        let timer = ResettableIdleTimer(queue: queue) {
            lock.withLock { count += 1 }
            fired.fulfill()
        }
        queue.sync { for _ in 0..<10_000 { timer.schedule(after: 0.05) } }
        await fulfillment(of: [fired], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(lock.withLock { count }, 1)
    }

    func testIdleTimerCanBeReleasedBeforeItsDeadline() async throws {
        let queue = DispatchQueue(label: "openvoice.tests.idle.release")
        let unexpected = expectation(description: "Cancelled idle deadline")
        unexpected.isInverted = true
        var timer: ResettableIdleTimer? = ResettableIdleTimer(queue: queue) { unexpected.fulfill() }
        weak var released = timer
        queue.sync { timer?.schedule(after: 0.03) }
        timer = nil
        XCTAssertNil(released)
        await fulfillment(of: [unexpected], timeout: 0.1)
    }

    @MainActor
    func testIncrementalPreviewRetainsExactUnicodeAcrossGraphemeRevisions() throws {
        _ = NSApplication.shared
        let view = DictationPreviewTextView()
        let font = NSFont.systemFont(ofSize: 14)
        let stable = String(repeating: "稳定前文 𠮷。", count: 100)
        for text in [stable + "e", stable + "e\u{301}", stable + "é", stable + "👨‍👩‍👦尾文",
                     stable + "👨‍👩‍👦‍👧尾文", stable + "🇨", stable + "🇨🇳", "", "新一轮\n完整尾字。"] {
            view.update(text, font: font, animated: true)
            XCTAssertEqual(Array(view.string.utf16), Array(text.utf16))
            XCTAssertEqual(view.font?.pointSize, font.pointSize)
        }
        view.finishReveals()
        let manager = try XCTUnwrap(view.layoutManager)
        for index in 0..<view.string.utf16.count {
            XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil))
        }
    }
}
