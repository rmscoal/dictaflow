import SwiftUI

struct ToneSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(TextTone.allCases) { tone in
                    Button { appState.updateTextTone(tone) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(glyph(tone)).font(.system(size: 27, weight: .medium))
                                Spacer()
                                if appState.textTone == tone { Image(systemName: "checkmark").font(.system(size: 12)) }
                            }
                            .padding(.bottom, 9)
                            Text(tone.title).font(.system(size: 13, weight: .medium))
                            Text(detail(tone)).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        }
                        .padding(18).frame(maxWidth: .infinity, minHeight: 135, alignment: .topLeading)
                        .foregroundStyle(appState.textTone == tone ? AppTheme.accent : AppTheme.primaryText)
                        .background(appState.textTone == tone ? AppTheme.selectedFill : AppTheme.tileFill,
                                    in: RoundedRectangle(cornerRadius: 20))
                        .overlay { RoundedRectangle(cornerRadius: 20).stroke(appState.textTone == tone ? AppTheme.accent : AppTheme.border, lineWidth: 1) }
                        .contentShape(RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.whisperSettingsLocked || appState.refinementSettingsLocked)
                    .accessibilityLabel("\(tone.title), \(detail(tone))")
                    .accessibilityAddTraits(appState.textTone == tone ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Text tone")
        }
    }

    private func glyph(_ tone: TextTone) -> String {
        switch tone { case .original, .formal: "Aa"; case .casual: "aa"; case .balanced: "Aa." }
    }

    private func detail(_ tone: TextTone) -> String {
        switch tone {
        case .original: "Keep as dictated"
        case .casual: "Relaxed casing"
        case .balanced: "Keep formatting"
        case .formal: "Expand contractions"
        }
    }
}
