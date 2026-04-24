import CryptoKit
import Foundation

protocol ModelDownloadServiceProtocol: AnyObject {
    var modelsDirectoryURL: URL { get }
    func ensureModelAvailable(
        _ model: WhisperModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL
}

enum ModelDownloadServiceError: LocalizedError {
    case couldNotCreateModelsDirectory
    case invalidServerResponse
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .couldNotCreateModelsDirectory:
            return "DictaFlow could not create its Whisper model folder."
        case .invalidServerResponse:
            return "The Whisper model download returned an invalid response."
        case .checksumMismatch:
            return "The downloaded Whisper model did not match its expected checksum."
        }
    }
}

actor WhisperModelDownloadService: ModelDownloadServiceProtocol {
    nonisolated let modelsDirectoryURL: URL

    private let fileManager: FileManager
    private let session: URLSession
    private var activeDownloads: [WhisperModelDescriptor: Task<URL, Error>] = [:]

    nonisolated init(
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.session = session
        self.modelsDirectoryURL = Self.makeModelsDirectoryURL(fileManager: fileManager)
    }

    func ensureModelAvailable(
        _ model: WhisperModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL {
        let destinationURL = modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)

        if fileManager.fileExists(atPath: destinationURL.path) {
            if try existingModelMatchesChecksum(at: destinationURL, expectedSHA1: model.sha1Checksum) {
                progressHandler(.located(destinationURL))
                return destinationURL
            }

            try? fileManager.removeItem(at: destinationURL)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            progressHandler(.located(destinationURL))
            return destinationURL
        }

        if let activeTask = activeDownloads[model] {
            return try await activeTask.value
        }

        let task = Task<URL, Error> { [fileManager, modelsDirectoryURL, session] in
            try Self.ensureModelsDirectoryExists(at: modelsDirectoryURL, using: fileManager)
            progressHandler(.starting(expectedBytes: nil))

            let temporaryURL = destinationURL.appendingPathExtension("download")
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }

            let (bytes, response) = try await session.bytes(from: model.downloadURL)

            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                throw ModelDownloadServiceError.invalidServerResponse
            }

            let expectedLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            fileManager.createFile(atPath: temporaryURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: temporaryURL)
            defer {
                try? outputHandle.close()
            }

            var bytesWritten: Int64 = 0
            var hasher = Insecure.SHA1()
            var chunkBuffer = Data()
            chunkBuffer.reserveCapacity(64 * 1024)

            for try await byte in bytes {
                chunkBuffer.append(byte)

                if chunkBuffer.count >= 64 * 1024 {
                    try outputHandle.write(contentsOf: chunkBuffer)
                    hasher.update(data: chunkBuffer)
                    bytesWritten += Int64(chunkBuffer.count)
                    chunkBuffer.removeAll(keepingCapacity: true)
                    progressHandler(.downloading(bytesWritten: bytesWritten, totalBytes: expectedLength))
                }
            }

            if !chunkBuffer.isEmpty {
                try outputHandle.write(contentsOf: chunkBuffer)
                hasher.update(data: chunkBuffer)
                bytesWritten += Int64(chunkBuffer.count)
                progressHandler(.downloading(bytesWritten: bytesWritten, totalBytes: expectedLength))
            }

            let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard checksum == model.sha1Checksum else {
                try? fileManager.removeItem(at: temporaryURL)
                throw ModelDownloadServiceError.checksumMismatch
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            progressHandler(.finished(destinationURL))
            return destinationURL
        }

        activeDownloads[model] = task

        do {
            let destinationURL = try await task.value
            activeDownloads[model] = nil
            return destinationURL
        } catch {
            activeDownloads[model] = nil
            throw error
        }
    }

    private static func makeModelsDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupportURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DictaFlow", isDirectory: true)
        return applicationSupportURL.appendingPathComponent("Models", isDirectory: true)
    }

    private static func ensureModelsDirectoryExists(at directoryURL: URL, using fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw ModelDownloadServiceError.couldNotCreateModelsDirectory
        }
    }

    private func existingModelMatchesChecksum(at fileURL: URL, expectedSHA1: String) throws -> Bool {
        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? inputHandle.close()
        }

        var hasher = Insecure.SHA1()

        while true {
            let data = try inputHandle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty {
                break
            }

            hasher.update(data: data)
        }

        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return checksum == expectedSHA1
    }
}
