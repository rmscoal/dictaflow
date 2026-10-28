import SwiftUI

/// Composes the EXAMPLE card output: the illustrative writing-style result
/// (or the original sample when refinement cannot run) passed through the
/// production final-formatting rules. No inference is performed.
nonisolated enum OutputExampleComposer {
    static let originalSample = "Hey um can you review the auth PR by Wednesday? I think it might fix the login issue but yeah we can't ship until we're done testing."

    static func output(refinementUsable: Bool, effectiveMode: RefinementMode, tone: TextTone) -> String {
        let source = refinementUsable && effectiveMode != .diy
            ? effectiveMode.writingExample
            : originalSample
        return TextToneFormatter.format(source, tone: tone, isEnglish: true).text
    }
}

struct OutputExampleView: View {
    @ObservedObject var appState: DictaFlowAppState

    /// Mirrors the dictation fallback: refinement only contributes when it
    /// is enabled and its runtime and selected model are ready.
    private var refinementUsable: Bool {
        appState.refinementConfiguration.isEnabled
            && appState.isRefinementRuntimeAvailable
            && appState.isSelectedRefinementModelPrepared
    }

    private var result: String {
        OutputExampleComposer.output(
            refinementUsable: refinementUsable,
            effectiveMode: appState.effectiveRefinementStyle.mode,
            tone: appState.textTone
        )
    }

    private var styleTagValue: String {
        guard refinementUsable else { return "Off" }
        // DIY custom instructions are never executed in the preview.
        return appState.effectiveRefinementStyle.mode == .diy
            ? "DIY (not previewed)"
            : appState.effectiveRefinementStyle.mode.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("EXAMPLE")
                        .font(.system(size: 11)).tracking(1.1)
                    Spacer()
                }
                .foregroundStyle(AppTheme.paperSecondaryText).padding(.bottom, 30)
                caption("As dictated")
                Text(OutputExampleComposer.originalSample).font(.system(size: 13)).lineSpacing(7)
                    .foregroundStyle(AppTheme.paperSecondaryText).padding(.top, 10).padding(.bottom, 25)
                Rectangle().fill(AppTheme.paperBorder).frame(height: 1)
                caption("Result").padding(.top, 25)
                Text(result).font(.system(size: 21)).tracking(-0.35).lineSpacing(9)
                    .foregroundStyle(AppTheme.paperText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10).padding(.bottom, 30)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    tag(label: "Style", value: styleTagValue)
                    tag(label: "Formatting", value: appState.textTone.finalFormattingTitle)
                    Spacer(minLength: 0)
                }
                .padding(.top, 16)
            }
            .padding(24).frame(maxWidth: .infinity, minHeight: 410, alignment: .topLeading)
            .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.paperBorder, lineWidth: 1) }
        }
        .help("Sample text. Custom instructions apply only to actual dictation.")
        .accessibilityElement(children: .contain).accessibilityLabel("Example using sample text, without custom instructions")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(AppTheme.paperSecondaryText)
    }

    private func tag(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":").foregroundStyle(AppTheme.paperSecondaryText)
            Text(value).fontWeight(.semibold).foregroundStyle(AppTheme.paperText)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .overlay { Capsule().stroke(AppTheme.paperBorder, lineWidth: 1) }
    }
}
