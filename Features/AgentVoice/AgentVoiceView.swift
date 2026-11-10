import SwiftUI

/// Dedicated Agent Voice destination. Tabs always appear in the order
/// Connections, Models, History, and Connections is the default landing tab.
struct AgentVoiceView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        EmberPage {
            EmberPageHeading(title: "Agent Voice")
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
            .padding(.bottom, 26)
            .accessibilityElement(children: .contain).accessibilityLabel("Agent Voice sections")

            if let voice = appState.agentVoice {
                switch appState.agentVoiceTab {
                case .connections: AgentVoiceConnectionsTab(voice: voice)
                case .models: AgentVoiceModelsTab(voice: voice)
                case .history: AgentVoiceHistoryTab(voice: voice)
                }
            } else {
                Text("Agent Voice is unavailable in this session.")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            }
        }
    }
}

enum AgentVoiceTab: String, CaseIterable, Identifiable {
    case connections, models, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connections: "MCP Connections"
        case .models: "Models"
        case .history: "History"
        }
    }
}
