import SwiftUI

/// Display common Markdown blocks with native text. Raw HTML remains inert text.
/// Parsing is only for preview; the original source is saved and sent unchanged.
struct MarkdownPromptPreview: View {
    let source: String
    private struct Block: Identifiable {
        let id: Int
        let text: String
        let heading: Int
        let isCode: Bool
        let isBullet: Bool
    }
    private var blocks: [Block] {
        var result: [Block] = []
        var code = false
        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") { code.toggle(); continue }
            let heading = code ? 0 : line.prefix(while: { $0 == "#" }).count
            let isHeading = (1...6).contains(heading) && line.dropFirst(heading).hasPrefix(" ")
            let bullet = !code && line.hasPrefix("- ")
            let text = isHeading ? String(line.dropFirst(heading + 1)) : (bullet ? String(line.dropFirst(2)) : line)
            result.append(Block(id: result.count, text: text.isEmpty ? " " : text,
                                heading: isHeading ? heading : 0, isCode: code, isBullet: bullet))
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                HStack(alignment: .top, spacing: 6) {
                    if block.isBullet { Text("•") }
                    if block.isCode {
                        Text(block.text).font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4).background(AppTheme.controlFill)
                    } else {
                        Text((try? AttributedString(markdown: block.text,
                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                            .font(block.heading == 1 ? .title2 : (block.heading > 0 ? .headline : .body))
                    }
                }
            }
        }.textSelection(.enabled)
    }
}
