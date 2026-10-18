import SwiftUI

struct DictationWorkspaceView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - AppLayout.contentPadding * 2
            EmberPage {
                EmberPageHeading(title: "Dictation")
                HStack(alignment: .top, spacing: contentWidth > 760 ? 12 : 8) {
                    stage(.transcription, index: 1, value: "Whisper \(appState.whisperConfiguration.model.displayName)", detail: appState.whisperConfiguration.inputLanguage.displayName, asset: "provider-openai", compact: contentWidth <= 760)
                    stage(.refinement, index: 2, value: appState.refinementConfiguration.isEnabled ? appState.refinementConfiguration.model.displayName : "Refinement off", detail: appState.refinementConfiguration.isEnabled ? appState.effectiveRefinementStyle.mode.title + (appState.refinementConfiguration.perAppStylesEnabled ? " · Per-app on" : "") : "Optional", asset: appState.refinementConfiguration.model.provider?.iconName, compact: contentWidth <= 760)
                    stage(.tone, index: 3, value: appState.textTone.title, detail: "", asset: nil, compact: contentWidth <= 760)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)
                .accessibilityElement(children: .contain).accessibilityLabel("Dictation settings")
                EmberColumns {
                    VStack(alignment: .leading, spacing: 0) {
                        switch appState.dictationSettingsTab {
                        case .transcription: TranscriptionSettingsView(appState: appState)
                        case .refinement: RefinementSettingsView(appState: appState)
                        case .tone: ToneSettingsView(appState: appState)
                        }
                    }
                    OutputExampleView(appState: appState)
                }
            }
        }
    }

    private func stage(_ tab: DictationSettingsTab, index: Int, value: String, detail: String, asset: String?, compact: Bool) -> some View {
        DictationStageCard(tab: tab, index: index, value: value, detail: detail, providerAsset: asset,
                           selected: appState.dictationSettingsTab == tab, compact: compact) {
            appState.dictationSettingsTab = tab
        }
    }
}
