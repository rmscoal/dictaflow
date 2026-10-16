import SwiftUI

struct CustomVocabularyEditor: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var inputText = ""
    @State private var error: CustomVocabularyKeywordError?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appState.whisperConfiguration.customVocabulary.isEmpty {
                KeywordTagLayout {
                    ForEach(appState.whisperConfiguration.customVocabulary, id: \.self) { keyword in
                        KeywordTag(text: keyword) {
                            error = nil
                            appState.removeCustomVocabularyKeyword(keyword)
                        }
                        .disabled(appState.whisperSettingsLocked)
                    }
                }
            }

            TextField("Type a keyword and press Return", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .disabled(appState.whisperSettingsLocked)
                .onSubmit(commitKeyword)
                .onChange(of: inputText) { _, newValue in
                    error = nil
                    let stripped = newValue.filter { $0 != "," }
                    if stripped != newValue {
                        inputText = stripped
                    }
                }

            Text(helperText)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)

            if let error {
                Text(error.message)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }

    private var helperText: String {
        let count = appState.whisperConfiguration.customVocabulary.count
        return "Single words only · \(count) of \(WhisperConfiguration.maxCustomVocabularyTerms) keywords"
    }

    private func commitKeyword() {
        error = appState.addCustomVocabularyKeyword(inputText)
        if error == nil {
            inputText = ""
        }
    }
}

private struct KeywordTag: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryText)
            .help("Remove \(text)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(AppTheme.controlFill, in: Capsule())
    }
}

private struct KeywordTagLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else {
            return .zero
        }

        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + verticalSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            rowWidth += size.width + horizontalSpacing
        }

        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
    }
}
