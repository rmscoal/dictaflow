import SwiftUI

struct OutputExampleView: View {
    @ObservedObject var appState: DictaFlowAppState
    private let original = "Hey um can you review the auth PR by Wednesday? I think it might fix the login issue but yeah we still need to test it."
    private let toneExample = "Hmm, I'm gonna be late. There's a cute dog outside. I can't just walk past him."

    private var isTone: Bool { appState.dictationSettingsTab == .tone }
    private var result: String {
        let source = isTone ? toneExample : appState.refinementConfiguration.isEnabled && appState.refinementConfiguration.mode != .diy ? appState.refinementConfiguration.mode.writingExample : original
        return isTone ? TextToneFormatter.format(source, tone: appState.textTone, isEnglish: true).text : source
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
                Text(isTone ? toneExample : original).font(.system(size: 13)).lineSpacing(7)
                    .foregroundStyle(AppTheme.paperSecondaryText).padding(.top, 10).padding(.bottom, 25)
                Rectangle().fill(AppTheme.paperBorder).frame(height: 1)
                caption(isTone ? appState.textTone.title : "Ready to share").padding(.top, 25)
                Text(result).font(.system(size: 21)).tracking(-0.35).lineSpacing(9)
                    .foregroundStyle(AppTheme.paperText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10).padding(.bottom, 30)
                Spacer(minLength: 0)
                if isTone {
                    Rectangle().fill(AppTheme.paperBorder).frame(height: 1)
                    HStack {
                        Label("\(appState.textTone.title) tone", systemImage: "slider.horizontal.3")
                        Spacer()
                    }
                    .font(.system(size: 11)).foregroundStyle(AppTheme.paperSecondaryText).padding(.top, 16)
                }
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
}
