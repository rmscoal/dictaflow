import CryptoKit
import Foundation

protocol ModelDownloadServiceProtocol: AnyObject {
    var modelsDirectoryURL: URL { get }
    func ensureModelAvailable(
        _ model: WhisperModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL
    func ensureRefinementModelAvailable(
        _ model: RefinementModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL
    func isRefinementModelPrepared(_ model: RefinementModelDescriptor) -> Bool
    func preparedRefinementModelURL(for model: RefinementModelDescriptor) -> URL?
}

enum ModelDownloadServiceError: LocalizedError {
    case couldNotCreateModelsDirectory
    case invalidServerResponse
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .couldNotCreateModelsDirectory:
            return "DictaFlow could not create its local model folder."
        case .invalidServerResponse:
            return "The model download returned an invalid response."
        case .checksumMismatch:
            return "The downloaded model did not match its expected checksum."
        }
    }
}

actor WhisperModelDownloadService: ModelDownloadServiceProtocol {
    nonisolated let modelsDirectoryURL: URL

    private let fileManager: FileManager
    private let session: URLSession
    private var activeDownloads: [String: Task<URL, Error>] = [:]

    init(
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
        try await ensureLocalModelAvailable(model, progressHandler: progressHandler)
    }

    func ensureRefinementModelAvailable(
        _ model: RefinementModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL {
        try await ensureLocalModelAvailable(model, progressHandler: progressHandler)
    }

    nonisolated func isRefinementModelPrepared(_ model: RefinementModelDescriptor) -> Bool {
        let modelURL = modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    nonisolated func preparedRefinementModelURL(for model: RefinementModelDescriptor) -> URL? {
        let modelURL = modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)
        return FileManager.default.fileExists(atPath: modelURL.path) ? modelURL : nil
    }

    private func ensureLocalModelAvailable<Model: LocalModelDescriptor>(
        _ model: Model,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL {
        let destinationURL = modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)

        if fileManager.fileExists(atPath: destinationURL.path) {
            if try Self.modelFileMatchesChecksum(at: destinationURL, expectedChecksum: model.checksum) {
                progressHandler(.located(destinationURL))
                return destinationURL
            }

            try? fileManager.removeItem(at: destinationURL)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            progressHandler(.located(destinationURL))
            return destinationURL
        }

        if let activeTask = activeDownloads[model.modelIdentifier] {
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
            var chunkBuffer = Data()
            chunkBuffer.reserveCapacity(64 * 1024)

            for try await byte in bytes {
                chunkBuffer.append(byte)

                if chunkBuffer.count >= 64 * 1024 {
                    try outputHandle.write(contentsOf: chunkBuffer)
                    bytesWritten += Int64(chunkBuffer.count)
                    chunkBuffer.removeAll(keepingCapacity: true)
                    progressHandler(.downloading(bytesWritten: bytesWritten, totalBytes: expectedLength))
                }
            }

            if !chunkBuffer.isEmpty {
                try outputHandle.write(contentsOf: chunkBuffer)
                bytesWritten += Int64(chunkBuffer.count)
                progressHandler(.downloading(bytesWritten: bytesWritten, totalBytes: expectedLength))
            }

            try outputHandle.synchronize()
            try outputHandle.close()

            guard try Self.modelFileMatchesChecksum(at: temporaryURL, expectedChecksum: model.checksum) else {
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

        activeDownloads[model.modelIdentifier] = task

        do {
            let destinationURL = try await task.value
            activeDownloads[model.modelIdentifier] = nil
            return destinationURL
        } catch {
            activeDownloads[model.modelIdentifier] = nil
            throw error
        }
    }

    nonisolated private static func makeModelsDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupportURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DictaFlow", isDirectory: true)
        return applicationSupportURL.appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated private static func ensureModelsDirectoryExists(at directoryURL: URL, using fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw ModelDownloadServiceError.couldNotCreateModelsDirectory
        }
    }

    nonisolated private static func modelFileMatchesChecksum(at fileURL: URL, expectedChecksum: ModelChecksum) throws -> Bool {
        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? inputHandle.close()
        }

        switch expectedChecksum {
        case .sha1(let expectedSHA1):
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
        case .sha256(let expectedSHA256):
            var hasher = SHA256()

            while true {
                let data = try inputHandle.read(upToCount: 64 * 1024) ?? Data()
                if data.isEmpty {
                    break
                }

                hasher.update(data: data)
            }

            let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return checksum == expectedSHA256
        }
    }
}
