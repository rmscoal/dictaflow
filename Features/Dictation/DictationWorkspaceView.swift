import SwiftUI

private struct DictationExampleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct DictationWorkspaceView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var columnsFrame: CGRect = .zero
    @State private var exampleHeight: CGFloat = 0

    /// Gap kept between the pinned example and the top of the scroll viewport.
    private static let stickyTopInset: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - AppLayout.contentPadding * 2
            let sideBySide = contentWidth > AppLayout.workspaceStackingWidth
            let stickyOffset = stickyOffset(sideBySide: sideBySide)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EmberPageHeading(title: "Dictation")
                    HStack(alignment: .top, spacing: contentWidth > AppLayout.workspaceStackingWidth ? 12 : 8) {
                        stage(.transcription, index: 1, value: "Whisper \(appState.whisperConfiguration.model.displayName)", detail: appState.whisperConfiguration.inputLanguage.displayName, asset: "provider-openai", compact: contentWidth <= AppLayout.workspaceStackingWidth)
                        stage(.refinement, index: 2, value: appState.refinementConfiguration.isEnabled ? appState.refinementConfiguration.model.displayName : "Refinement off", detail: appState.refinementConfiguration.isEnabled ? appState.effectiveRefinementStyle.mode.title + (appState.refinementConfiguration.perAppStylesEnabled ? " · Per-app on" : "") : "Optional", asset: appState.refinementConfiguration.model.provider?.iconName, compact: contentWidth <= AppLayout.workspaceStackingWidth)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 22)
                    .accessibilityElement(children: .contain).accessibilityLabel("Dictation settings")
                    EmberColumns {
                        VStack(alignment: .leading, spacing: 0) {
                            switch appState.dictationSettingsTab {
                            case .transcription: TranscriptionSettingsView(appState: appState)
                            case .refinement: RefinementSettingsView(appState: appState)
                            }
                        }
                        OutputExampleView(appState: appState, compact: sideBySide && geometry.size.height < 640)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: DictationExampleHeightKey.self, value: proxy.size.height)
                                }
                            }
                            .offset(y: stickyOffset)
                    }
                    .background {
                        ScrollViewportPositionReader { frame in
                            if columnsFrame != frame { columnsFrame = frame }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, AppLayout.contentPadding)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(DictationExampleHeightKey.self) { exampleHeight = $0 }
        }
    }

    /// Pushes the example down only enough to keep its top at the viewport
    /// inset, bounded so its bottom never passes the two-column region.
    private func stickyOffset(sideBySide: Bool) -> CGFloat {
        guard sideBySide, columnsFrame.height > 0, exampleHeight > 0 else { return 0 }
        let pinnedTop = Self.stickyTopInset
        let desired = pinnedTop - columnsFrame.minY
        let maximum = max(0, columnsFrame.height - exampleHeight)
        return min(max(desired, 0), maximum)
    }

    private func stage(_ tab: DictationSettingsTab, index: Int, value: String, detail: String, asset: String?, compact: Bool) -> some View {
        DictationStageCard(tab: tab, index: index, value: value, detail: detail, providerAsset: asset,
                           selected: appState.dictationSettingsTab == tab, compact: compact) {
            appState.dictationSettingsTab = tab
        }
    }
}
