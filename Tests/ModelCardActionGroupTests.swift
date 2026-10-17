import AppKit
import SwiftUI
import XCTest
@testable import DictaFlow_Dev

/// Guards the refinement card action group against layout inflation: the
/// model row offers the group the full row height, and the group must stay
/// the height of a standard button instead of stretching to fill it.
final class ModelCardActionGroupTests: XCTestCase {
    private struct ReportedSizeKey: PreferenceKey {
        nonisolated static var defaultValue: CGSize { .zero }
        nonisolated static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }

    /// Hosts a view with a tall definite proposal, mimicking the model row,
    /// and reports the size the view actually takes.
    private func renderedHeight<V: View>(of view: V) -> CGFloat {
        var size: CGSize = .zero
        let content = AnyView(view)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ReportedSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(ReportedSizeKey.self) { size = $0 }
        let host = NSHostingView(
            rootView: AnyView(
                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: 180, height: 100)
                    content
                }
                .frame(width: 300)
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        return size.height
    }

    func testGroupMatchesStandardButtonHeightUnderTallProposal() {
        let button = Button("Download") {}.buttonStyle(EmberButtonStyle())
        let group = ModelCardActionGroup(
            useDisabled: false,
            onUse: {},
            removeDisabled: false,
            onRemove: {},
            removeHelp: "Remove Fixture"
        )
        XCTAssertEqual(renderedHeight(of: group), renderedHeight(of: button), accuracy: 1)
    }
}
