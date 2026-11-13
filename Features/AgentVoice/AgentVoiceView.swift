import SwiftUI

/// General contains playback, the shared speech model, and host setup.
/// History gets the available window height for its conversation browser.
struct AgentVoiceView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        // History is a window-filling browser like recording history, so it
        // lives outside the scrolling page; the split view takes the rest of
        // the window instead of collapsing to its content.
        if appState.agentVoiceTab == .history, let voice = appState.agentVoice {
            VStack(alignment: .leading, spacing: 0) {
                header
                AgentVoiceHistoryTab(voice: voice, appState: appState) { appState.copyVoiceHistoryText($0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, AppLayout.contentPadding).padding(.top, 10).padding(.bottom, 28)
        } else {
            EmberPage {
                header
                tabBody
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                ForEach(AgentVoiceTab.allCases) { tab in
                    Button { appState.agentVoiceTab = tab } label: {
                        Text(tab.title).font(.system(size: 12))
                            .frame(minWidth: 82).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(appState.agentVoiceTab == tab ? AppTheme.tileFill : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent-voice-\(tab.rawValue)")
                    .accessibilityAddTraits(appState.agentVoiceTab == tab ? .isSelected : [])
                }
            }
            .padding(3).background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border, lineWidth: 1) }
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain).accessibilityLabel("Agent Voice sections")
        }
    }

    private var tabBody: some View {
        Group {
            if let voice = appState.agentVoice {
                switch appState.agentVoiceTab {
                case .general: AgentVoiceConnectionsTab(voice: voice) { appState.copySetupSnippet($0) }
                case .history: AgentVoiceHistoryTab(voice: voice, appState: appState) { appState.copyVoiceHistoryText($0) }
                }
            } else {
                Text("Agent Voice is unavailable in this session.")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            }
        }
    }
}

enum AgentVoiceTab: String, CaseIterable, Identifiable {
    case general, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .history: "History"
        }
    }
}
