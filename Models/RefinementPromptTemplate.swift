import Foundation

enum RefinementPromptTemplate {
    nonisolated static let languageInstructionPlaceholder = "{{languageInstruction}}"

    nonisolated static var defaultTemplate: String {
        """
            Clean up the transcript.
            Output only the corrected text.
            \(languageInstructionPlaceholder)

            Rules:
            - Preserve meaning.
            - Preserve names, numbers, dates, URLs, code, and commands.
            - Remove filler words, repetitions, false starts, and speech disfluencies.
            - Resolve self-corrections by keeping the final intended wording.
            - Fix grammar, punctuation, capitalization, and spacing.
            - Rewrite awkward dictated speech into natural written language.
            - Compress redundant wording.
            - Preserve distinct ideas, requests, facts, and action items.
            - Format paragraphs for readability.
            - Convert spoken enumerations into numbered lists when clearly intended.
            - Use bullet points for clear itemized lists.
            - Do not add information.
            - Do not explain changes.
        """
    }

    nonisolated static func renderedInstructions(
        from template: String,
        whisperTaskMode: WhisperTaskMode
    ) -> String {
        let baseTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultTemplate
            : template

        let languageInstruction: String
        switch whisperTaskMode {
        case .transcribe:
            languageInstruction = "Preserve the original language."
        case .translateToEnglish:
            languageInstruction = "Output English."
        }

        if baseTemplate.contains(languageInstructionPlaceholder) {
            return baseTemplate.replacingOccurrences(
                of: languageInstructionPlaceholder,
                with: languageInstruction
            )
        }

        return """
        \(baseTemplate)
        \(languageInstruction)
        """
    }
}
