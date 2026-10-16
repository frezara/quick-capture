import XCTest
import AppKit
@testable import QuickCapture

/// Callback-to-input proxy: does not include macOS global-hotkey dispatch latency.
@MainActor
final class CaptureLatencyTests: XCTestCase {
    func testCaptureLatencyEvidence() async throws {
        guard ProcessInfo.processInfo.environment["QC_MEASURE_LATENCY"] == "1" else { throw XCTSkip("Opt-in UI latency measurement") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc-latency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState()
        let originalPath = state.captureFilePath
        defer { state.captureFilePath = originalPath }
        let fixture = root.appendingPathComponent("inbox.md")
        state.captureFilePath = fixture.path
        for count in [100, 10000] {
            let content = "# Inbox\n\n## Quick capture\n" + (0..<count).map { "- [ ] Fixture item \($0)\n" }.joined()
            try content.write(to: fixture, atomically: true, encoding: .utf8)
            var cold: [Double] = [], warm: [Double] = [], saves: [Double] = []
            for _ in 0..<3 {
                let start = CFAbsoluteTimeGetCurrent()
                state.refreshRecentTags()
                let panel = MainPanel(appState: state, onSubmit: { _,_,_ in true }, onDismiss: {})
                panel.show()
                try await waitForInput(panel)
                cold.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                for _ in 0..<10 {
                    panel.orderOut(nil)
                    let t = CFAbsoluteTimeGetCurrent()
                    state.refreshRecentTags(); panel.show()
                    try await waitForInput(panel)
                    warm.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                }
                panel.orderOut(nil)
            }
            for _ in 0..<30 {
                try content.write(to: fixture, atomically: true, encoding: .utf8)
                let t = CFAbsoluteTimeGetCurrent()
                try FileWriter.appendTodo("Representative café capture", to: fixture)
                saves.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            func stats(_ values: [Double]) -> String {
                let sorted = values.sorted()
                return "n=\(values.count) median_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])"
            }
            print("QC_LATENCY items=\(count) cold \(stats(cold)) warm \(stats(warm)) save \(stats(saves))")
        }
    }
    private func waitForInput(_ panel: MainPanel) async throws {
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            if panel.isVisible, panel.firstResponder is NSTextView { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Input did not acquire first responder")
        throw NSError(domain: "Latency", code: 1)
    }
}
