import AppKit
import SwiftUI
import XCTest
@testable import DictaFlow_Dev

/// Guards the refinement card action group against layout inflation: the
/// model row offers the group the full row height, and the group must stay
/// the height of a standard button instead of stretching to fill it.
final class ModelCardActionGroupTests: XCTestCase {
    /// Measure the actual size the control reports under a definite, tall
    /// proposal. The hosted test app can do this without opening a window.
    private struct TallProposal: Layout {
        let childProposal = ProposedViewSize(width: 120, height: 100)

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews[0].sizeThatFits(childProposal)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews[0].place(at: bounds.origin, proposal: childProposal)
        }
    }

    private func renderedHeight<V: View>(of view: V) -> CGFloat {
        let host = NSHostingView(rootView: TallProposal { view })
        return host.fittingSize.height
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
        let buttonHeight = renderedHeight(of: button)
        XCTAssertGreaterThan(buttonHeight, 0)
        XCTAssertEqual(renderedHeight(of: group), buttonHeight, accuracy: 1)
    }
}
