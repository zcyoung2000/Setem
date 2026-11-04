import AppKit
import XCTest
@testable import OpenVoice

@MainActor
final class MeetingPanelTests: XCTestCase {
    func testNativeWindowAnimatesWithoutMovingTopRightAndHandlesRepeatedClicks() async throws {
        _ = NSApplication.shared
        let model = MeetingSession()
        let panel = MeetingPanel(model: model)
        panel.show()
        defer { panel.hide() }
        try await Task.sleep(for: .milliseconds(100))
        let initial = panel.frameForDiagnostics
        XCTAssertEqual(initial.size, NSSize(width: 292, height: 82))
        panel.toggle()
        var widths: [CGFloat] = []
        var anchorDrift: CGFloat = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(16))
            let frame = panel.frameForDiagnostics
            widths.append(frame.width)
            anchorDrift = max(anchorDrift, abs(frame.maxX - initial.maxX), abs(frame.maxY - initial.maxY))
        }
        let expanded = panel.frameForDiagnostics
        XCTAssertGreaterThan(expanded.height, initial.height)
        XCTAssertLessThanOrEqual(anchorDrift, 2)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertGreaterThan(Set(widths.map { Int($0.rounded()) }).count, 4, "Expansion must pass through intermediate sizes")
        }
        panel.toggle()
        try await Task.sleep(for: .milliseconds(45))
        panel.toggle()
        try await Task.sleep(for: .milliseconds(45))
        panel.toggle()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(panel.frameForDiagnostics.size, initial.size)
        XCTAssertEqual(panel.frameForDiagnostics.maxX, initial.maxX, accuracy: 1)
        XCTAssertEqual(panel.frameForDiagnostics.maxY, initial.maxY, accuracy: 1)
    }
}
