import AppKit
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class ScrollViewportPositionReaderTests: XCTestCase {
    func testReportsOnlyLatestPositionAfterScrollingStops() async throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let reader = ScrollViewportPositionReader.PositionView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        var frames: [CGRect] = []
        reader.onChange = { frames.append($0) }
        scrollView.documentView = reader
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = scrollView
        defer { window.contentView = nil }

        scrollView.contentView.bounds.origin.y = 100
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(frames.isEmpty)

        scrollView.contentView.bounds.origin.y = 200
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(frames.isEmpty, "Further scrolling must restart the delay")

        try await Task.sleep(for: .milliseconds(160))
        let clip = scrollView.contentView
        let expected = reader.convert(reader.bounds, to: clip)
            .offsetBy(dx: -clip.bounds.minX, dy: -clip.bounds.minY)
        XCTAssertEqual(frames, [expected])

        reader.layout()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(frames.count, 1, "Unchanged layout must not deliver another update")
    }

    func testDetachingCancelsPendingUpdate() async throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let reader = ScrollViewportPositionReader.PositionView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        var calls = 0
        reader.onChange = { _ in calls += 1 }
        scrollView.documentView = reader
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = scrollView
        defer { window.contentView = nil }
        scrollView.contentView.bounds.origin.y = 100
        reader.removeFromSuperview()
        reader.viewDidMoveToWindow()

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(calls, 0)
    }

    func testRemovingScrollViewFromWindowCancelsPendingUpdate() async throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let reader = ScrollViewportPositionReader.PositionView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        var calls = 0
        reader.onChange = { _ in calls += 1 }
        scrollView.documentView = reader
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = scrollView
        scrollView.contentView.bounds.origin.y = 100
        window.contentView = nil
        XCTAssertNil(reader.window)
        XCTAssertNotNil(reader.enclosingScrollView)

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(calls, 0)
    }
}
