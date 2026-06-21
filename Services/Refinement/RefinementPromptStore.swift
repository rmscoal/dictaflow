import Foundation

protocol RefinementPromptStoreProtocol: AnyObject {
    var promptsDirectoryURL: URL { get }
    func promptTemplate() -> String
    func hasCustomPromptTemplate() -> Bool
    func savePromptTemplate(_ template: String) throws
    func resetPromptTemplate() throws
}

enum RefinementPromptStoreError: LocalizedError {
    case couldNotCreateDirectory
    case invalidPromptFile
    case emptyPrompt

    var errorDescription: String? {
        switch self {
        case .couldNotCreateDirectory:
            return "DictaFlow could not create its local prompt folder."
        case .invalidPromptFile:
            return "The local prompt file is not a regular private text file."
        case .emptyPrompt:
            return "The refinement prompt cannot be empty."
        }
    }
}

final class FileRefinementPromptStore: RefinementPromptStoreProtocol {
    let promptsDirectoryURL: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.promptsDirectoryURL = Self.makePromptsDirectoryURL(fileManager: fileManager)
        try? migrateLegacyStandardPromptIfNeeded()
    }

    func promptTemplate() -> String {
        let promptURL = promptURL
        guard Self.isRegularPromptFile(at: promptURL),
              let prompt = try? String(contentsOf: promptURL, encoding: .utf8),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RefinementPromptTemplate.defaultTemplate
        }

        return prompt
    }

    func hasCustomPromptTemplate() -> Bool {
        let promptURL = promptURL
        guard Self.isRegularPromptFile(at: promptURL),
              let prompt = try? String(contentsOf: promptURL, encoding: .utf8) else {
            return false
        }

        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func savePromptTemplate(_ template: String) throws {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RefinementPromptStoreError.emptyPrompt
        }

        try Self.ensurePromptsDirectoryExists(at: promptsDirectoryURL, using: fileManager)
        let promptURL = promptURL

        if fileManager.fileExists(atPath: promptURL.path), !Self.isRegularPromptFile(at: promptURL) {
            throw RefinementPromptStoreError.invalidPromptFile
        }

        try template.write(to: promptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: promptURL.path
        )
    }

    func resetPromptTemplate() throws {
        let promptURL = promptURL
        guard fileManager.fileExists(atPath: promptURL.path) else {
            return
        }

        guard Self.isRegularPromptFile(at: promptURL) else {
            throw RefinementPromptStoreError.invalidPromptFile
        }

        try fileManager.removeItem(at: promptURL)
    }

    private var promptURL: URL {
        promptsDirectoryURL.appendingPathComponent("refinement.txt", isDirectory: false)
    }

    private func migrateLegacyStandardPromptIfNeeded() throws {
        guard !fileManager.fileExists(atPath: promptURL.path) else {
            return
        }

        let legacyURL = promptsDirectoryURL.appendingPathComponent("refinement-standard.txt", isDirectory: false)
        guard Self.isRegularPromptFile(at: legacyURL),
              let prompt = try? String(contentsOf: legacyURL, encoding: .utf8),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        try savePromptTemplate(prompt)
    }

    private static func makePromptsDirectoryURL(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DictaFlow", isDirectory: true)
            .appendingPathComponent("Prompts", isDirectory: true)
    }

    private static func ensurePromptsDirectoryExists(at directoryURL: URL, using fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )

            let resourceValues = try directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
                throw RefinementPromptStoreError.couldNotCreateDirectory
            }

            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directoryURL.path
            )
        } catch let error as RefinementPromptStoreError {
            throw error
        } catch {
            throw RefinementPromptStoreError.couldNotCreateDirectory
        }
    }

    private static func isRegularPromptFile(at fileURL: URL) -> Bool {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }

        return resourceValues.isRegularFile == true && resourceValues.isSymbolicLink != true
    }
}
