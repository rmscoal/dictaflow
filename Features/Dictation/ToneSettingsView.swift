import SwiftUI

/// Final formatting controls. The visible three-stop slider reuses the
/// persisted `TextTone` preference; only the presentation changed.
struct ToneSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState

    private var isLocked: Bool {
        appState.whisperSettingsLocked || appState.refinementSettingsLocked
    }

    private var selectedPosition: Int {
        appState.textTone.finalFormattingPosition
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(appState.textTone.finalFormattingPosition) },
            set: { newValue in
                let tone = TextTone.finalFormattingTone(at: Int(newValue.rounded()))
                guard tone != appState.textTone else { return }
                appState.updateTextTone(tone)
            }
        )
    }

    var body: some View {
        EmberPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Applies to every app, after the writing style.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                Slider(value: sliderValue, in: 0...2, step: 1)
                    .tint(AppTheme.accent)
                    .disabled(isLocked)
                    .accessibilityLabel("Final formatting")
                    .accessibilityValue(appState.textTone.finalFormattingTitle)
                HStack(spacing: 0) {
                    labelButton(title: "Casual", position: 0, alignment: .leading)
                    labelButton(title: "Original", position: 1, alignment: .center)
                    labelButton(title: "Formal", position: 2, alignment: .trailing)
                }
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Final formatting")
    }

    private func labelButton(title: String, position: Int, alignment: Alignment) -> some View {
        let isSelected = selectedPosition == position
        return Button {
            appState.updateTextTone(TextTone.finalFormattingTone(at: position))
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
