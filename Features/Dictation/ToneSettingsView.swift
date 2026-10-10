import SwiftUI

struct ToneSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState
    private let example = "Hmm, I'm gonna be late. There's a cute dog outside. I can't just walk past him."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tone").font(.headline)
            Picker("Tone", selection: Binding(get: { appState.textTone }, set: { appState.updateTextTone($0) })) {
                ForEach(TextTone.allCases) { tone in Text(tone.title).tag(tone) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(appState.whisperSettingsLocked || appState.refinementSettingsLocked)
            Text("Available with or without refinement.")
                .font(.caption).foregroundStyle(AppTheme.secondaryText)
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview").font(.caption).foregroundStyle(AppTheme.secondaryText)
                Text(TextToneFormatter.format(example, tone: appState.textTone, isEnglish: true).text)
                    .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border))
            Text("Tone adjusts formatting using fixed rules. Names and structured text are preserved where possible; rewriting uses refinement.")
                .font(.caption).foregroundStyle(AppTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
}
