import CryptoKit
import Foundation

protocol ModelDownloadServiceProtocol: AnyObject {
    var modelsDirectoryURL: URL { get }
    func installedModelFiles() -> [LocalModelFile]
    func deleteModelFiles(_ files: [LocalModelFile]) async throws -> Int64
    func cancelDownload(modelIdentifier: String)
    func removeIncompleteDownloads() -> Int64
    func ensureModelAvailable(
        _ model: WhisperModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL
    func ensureRefinementModelAvailable(
        _ model: RefinementModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL
    func isWhisperModelPrepared(_ model: WhisperModelDescriptor) -> Bool
    func verifiedWhisperModelURL(for model: WhisperModelDescriptor) async -> URL?
    func isWhisperEncoderPrepared(_ model: WhisperModelDescriptor) -> Bool
    func isWhisperEncoderDownloaded(_ model: WhisperModelDescriptor) -> Bool
    func setWhisperEncoderEnabled(_ enabled: Bool, for model: WhisperModelDescriptor) async throws
    func removeOrphanedEncoders() -> Int64
    func ensureWhisperEncoderAvailable(
        _ model: WhisperModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL
    func deleteWhisperEncoder(_ model: WhisperModelDescriptor) async throws -> Int64
    func isRefinementModelPrepared(_ model: RefinementModelDescriptor) -> Bool
    func verifiedRefinementModelURL(for model: RefinementModelDescriptor) async -> URL?
}

enum ModelDownloadServiceError: LocalizedError {
    case couldNotCreateModelsDirectory
    case couldNotCreateModelFile
    case invalidServerResponse
    case untrustedDownloadURL
    case downloadTooLarge
    case checksumMismatch
    case invalidLocalModelFile
    case invalidModelDeletionRequest
    case modelDeletionUnavailable
    case encoderExtractionFailed

    var errorDescription: String? {
        switch self {
        case .couldNotCreateModelsDirectory:
            return "DictaFlow could not create its local model folder."
        case .couldNotCreateModelFile:
            return "DictaFlow could not create its local model file."
        case .invalidServerResponse:
            return "The model download returned an invalid response."
        case .untrustedDownloadURL:
            return "DictaFlow can only download models over HTTPS."
        case .downloadTooLarge:
            return "The model download was larger than expected."
        case .checksumMismatch:
            return "The downloaded model did not match its expected checksum."
        case .invalidLocalModelFile:
            return "The local model path is not a regular file."
        case .invalidModelDeletionRequest:
            return "DictaFlow can only delete local model files it recognizes."
        case .modelDeletionUnavailable:
            return "A model is still being prepared. Try deleting unused models after it finishes."
        case .encoderExtractionFailed:
            return "DictaFlow could not unpack the Neural Engine encoder. Try downloading it again."
        }
    }
}

actor WhisperModelDownloadService: ModelDownloadServiceProtocol {
    // Retained only so existing downloads can be removed explicitly from Storage.
    nonisolated private static let retiredRefinementDirectory = "qwen3-0.6b-mlx-4bit"
    nonisolated private static let retiredRefinementIdentifier = "refinement.qwen3SmallMLX"

    nonisolated let modelsDirectoryURL: URL

    private let fileManager: FileManager
    private let session: URLSession
    private var activeDownloads: [String: Task<URL, Error>] = [:]
    private var activeExtractions: [String: Process] = [:]
    private var verifiedModelFingerprints: [String: VerifiedModelFingerprint] = [:]

    private struct VerifiedModelFingerprint: Equatable {
        let byteCount: Int64
        let modificationDate: Date
        let checksum: ModelChecksum
    }

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        modelsDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.session = session
        self.modelsDirectoryURL = modelsDirectoryURL ?? Self.makeModelsDirectoryURL(fileManager: fileManager)
    }

    func ensureModelAvailable(
        _ model: WhisperModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL {
        try await ensureLocalModelAvailable(
            modelIdentifier: model.modelIdentifier,
            filename: model.filename,
            downloadURL: model.downloadURL,
            checksum: model.checksum,
            maximumDownloadSizeBytes: model.maximumDownloadSizeBytes,
            progressHandler: progressHandler
        )
    }

    func ensureRefinementModelAvailable(
        _ model: RefinementModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL {
        return try await ensureLocalModelAvailable(
            modelIdentifier: model.modelIdentifier,
            filename: model.filename,
            downloadURL: model.downloadURL,
            checksum: model.checksum,
            maximumDownloadSizeBytes: model.maximumDownloadSizeBytes,
            progressHandler: progressHandler
        )
    }

    nonisolated func installedModelFiles() -> [LocalModelFile] {
        Self.installedModelFiles(in: modelsDirectoryURL, fileManager: .default)
    }

    func cancelDownload(modelIdentifier: String) {
        activeDownloads[modelIdentifier]?.cancel()

        if let extraction = activeExtractions.removeValue(forKey: modelIdentifier) {
            extraction.terminate()
        }
    }

    nonisolated func removeIncompleteDownloads() -> Int64 {
        Self.removeIncompleteDownloads(in: modelsDirectoryURL, fileManager: .default)
    }

    func deleteModelFiles(_ files: [LocalModelFile]) async throws -> Int64 {
        let uniqueFiles = files.reduce(into: [LocalModelFile]()) { result, file in
            guard !result.contains(where: { $0.modelIdentifier == file.modelIdentifier }) else {
                return
            }

            result.append(file)
        }

        for file in uniqueFiles {
            guard activeDownloads[file.modelIdentifier] == nil,
                  activeExtractions[file.modelIdentifier] == nil else {
                throw ModelDownloadServiceError.modelDeletionUnavailable
            }

            guard let expectedURL = Self.knownModelURL(for: file, in: modelsDirectoryURL),
                  expectedURL.standardizedFileURL.path == file.fileURL.standardizedFileURL.path else {
                throw ModelDownloadServiceError.invalidModelDeletionRequest
            }
        }

        var deletedByteCount: Int64 = 0

        for file in uniqueFiles {
            guard let fileURL = Self.knownModelURL(for: file, in: modelsDirectoryURL) else {
                throw ModelDownloadServiceError.invalidModelDeletionRequest
            }

            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                continue
            }

            if file.category == .whisperEncoder {
                guard isDirectory.boolValue else {
                    continue
                }

                deletedByteCount += Self.directoryByteCount(at: fileURL)
                try fileManager.removeItem(at: fileURL)

                if let model = WhisperModelDescriptor.allCases.first(where: { $0.encoderModelIdentifier == file.modelIdentifier }) {
                    let zipURL = modelsDirectoryURL.appendingPathComponent(model.encoderZipFilename, isDirectory: false)
                    if fileManager.fileExists(atPath: zipURL.path) {
                        deletedByteCount += Self.byteCount(at: zipURL, fileManager: fileManager)
                        try? fileManager.removeItem(at: zipURL)
                    }
                }

                continue
            }

            if file.modelIdentifier == Self.retiredRefinementIdentifier {
                guard isDirectory.boolValue else { throw ModelDownloadServiceError.modelDeletionUnavailable }
                deletedByteCount += Self.directoryByteCount(at: fileURL)
                try fileManager.removeItem(at: fileURL)
                continue
            }
            guard !isDirectory.boolValue else { continue }

            deletedByteCount += Self.byteCount(at: fileURL, fileManager: fileManager)
            try fileManager.removeItem(at: fileURL)
            verifiedModelFingerprints[file.modelIdentifier] = nil
        }

        return deletedByteCount
    }

    nonisolated func isRefinementModelPrepared(_ model: RefinementModelDescriptor) -> Bool {
        let modelURL = modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)
        return Self.isRegularModelFile(at: modelURL)
    }

    nonisolated func isWhisperModelPrepared(_ model: WhisperModelDescriptor) -> Bool {
        let modelURL = modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)
        return Self.isRegularModelFile(at: modelURL)
    }

    func verifiedWhisperModelURL(for model: WhisperModelDescriptor) async -> URL? {
        verifiedModelURL(for: model)
    }

    nonisolated func isWhisperEncoderPrepared(_ model: WhisperModelDescriptor) -> Bool {
        let directoryURL = modelsDirectoryURL.appendingPathComponent(model.encoderDirectoryName, isDirectory: true)
        return Self.isValidEncoderDirectory(at: directoryURL)
    }

    nonisolated func isWhisperEncoderDownloaded(_ model: WhisperModelDescriptor) -> Bool {
        if isWhisperEncoderPrepared(model) {
            return true
        }

        let disabledURL = modelsDirectoryURL.appendingPathComponent(model.encoderDisabledDirectoryName, isDirectory: true)
        return Self.isValidEncoderDirectory(at: disabledURL)
    }

    func setWhisperEncoderEnabled(_ enabled: Bool, for model: WhisperModelDescriptor) async throws {
        guard activeDownloads[model.encoderModelIdentifier] == nil,
              activeExtractions[model.encoderModelIdentifier] == nil else {
            throw ModelDownloadServiceError.modelDeletionUnavailable
        }

        let activeURL = modelsDirectoryURL.appendingPathComponent(model.encoderDirectoryName, isDirectory: true)
        let disabledURL = modelsDirectoryURL.appendingPathComponent(model.encoderDisabledDirectoryName, isDirectory: false)

        if enabled {
            guard !Self.isValidEncoderDirectory(at: activeURL),
                  Self.isValidEncoderDirectory(at: disabledURL) else {
                return
            }

            try fileManager.moveItem(at: disabledURL, to: activeURL)
        } else {
            guard Self.isValidEncoderDirectory(at: activeURL),
                  !fileManager.fileExists(atPath: disabledURL.path) else {
                return
            }

            try fileManager.moveItem(at: activeURL, to: disabledURL)
        }
    }

    nonisolated func removeOrphanedEncoders() -> Int64 {
        var freedByteCount: Int64 = 0

        for model in WhisperModelDescriptor.allCases {
            let stagingURL = modelsDirectoryURL.appendingPathComponent(model.encoderDirectoryName + ".extracting", isDirectory: true)
            var isStagingDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: stagingURL.path, isDirectory: &isStagingDirectory),
               isStagingDirectory.boolValue {
                freedByteCount += Self.directoryByteCount(at: stagingURL)
                try? FileManager.default.removeItem(at: stagingURL)
            }

            let modelURL = modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)
            var isRegular = ObjCBool(false)
            if FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isRegular), !isRegular.boolValue {
                continue
            }

            for directoryName in [model.encoderDirectoryName, model.encoderDisabledDirectoryName] {
                let directoryURL = modelsDirectoryURL.appendingPathComponent(directoryName, isDirectory: true)
                var isDirectory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }

                freedByteCount += Self.directoryByteCount(at: directoryURL)
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        return freedByteCount
    }

    func ensureWhisperEncoderAvailable(
        _ model: WhisperModelDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL {
        let directoryURL = modelsDirectoryURL.appendingPathComponent(model.encoderDirectoryName, isDirectory: true)
        let zipURL = modelsDirectoryURL.appendingPathComponent(model.encoderZipFilename, isDirectory: false)

        if Self.isValidEncoderDirectory(at: directoryURL) {
            try? fileManager.removeItem(at: zipURL)
            progressHandler(.located(directoryURL))
            return directoryURL
        }

        try? fileManager.removeItem(at: directoryURL)

        _ = try await ensureLocalModelAvailable(
            modelIdentifier: model.encoderModelIdentifier,
            filename: model.encoderZipFilename,
            downloadURL: model.encoderDownloadURL,
            checksum: model.encoderChecksum,
            maximumDownloadSizeBytes: model.encoderMaximumDownloadSizeBytes,
            progressHandler: progressHandler
        )

        let stagingURL = modelsDirectoryURL.appendingPathComponent(model.encoderDirectoryName + ".extracting", isDirectory: true)
        try? fileManager.removeItem(at: stagingURL)

        do {
            try await extractZip(at: zipURL, toDirectory: stagingURL, modelIdentifier: model.encoderModelIdentifier)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        try? fileManager.removeItem(at: zipURL)

        let extractedURL = stagingURL.appendingPathComponent(model.encoderDirectoryName, isDirectory: true)

        guard Self.isValidEncoderDirectory(at: extractedURL) else {
            try? fileManager.removeItem(at: stagingURL)
            throw ModelDownloadServiceError.encoderExtractionFailed
        }

        do {
            try fileManager.moveItem(at: extractedURL, to: directoryURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw ModelDownloadServiceError.encoderExtractionFailed
        }

        try? fileManager.removeItem(at: stagingURL)
        return directoryURL
    }

    func deleteWhisperEncoder(_ model: WhisperModelDescriptor) async throws -> Int64 {
        guard activeDownloads[model.encoderModelIdentifier] == nil,
              activeExtractions[model.encoderModelIdentifier] == nil else {
            throw ModelDownloadServiceError.modelDeletionUnavailable
        }

        var deletedByteCount: Int64 = 0

        for directoryName in [model.encoderDirectoryName, model.encoderDisabledDirectoryName] {
            let directoryURL = modelsDirectoryURL.appendingPathComponent(directoryName, isDirectory: true)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            deletedByteCount += Self.directoryByteCount(at: directoryURL)
            try fileManager.removeItem(at: directoryURL)
        }

        let zipURL = modelsDirectoryURL.appendingPathComponent(model.encoderZipFilename, isDirectory: false)
        if fileManager.fileExists(atPath: zipURL.path) {
            deletedByteCount += Self.byteCount(at: zipURL, fileManager: fileManager)
            try? fileManager.removeItem(at: zipURL)
        }

        return deletedByteCount
    }

    func verifiedRefinementModelURL(for model: RefinementModelDescriptor) async -> URL? {
        return verifiedModelURL(for: model)
    }

    private func verifiedModelURL<Model: LocalModelDescriptor>(for model: Model, directory: URL? = nil) -> URL? {
        let modelURL = (directory ?? modelsDirectoryURL).appendingPathComponent(model.filename, isDirectory: false)
        guard Self.isRegularModelFile(at: modelURL),
              let fingerprint = Self.fingerprint(at: modelURL, expectedChecksum: model.checksum) else {
            verifiedModelFingerprints[model.modelIdentifier] = nil
            return nil
        }

        if verifiedModelFingerprints[model.modelIdentifier] == fingerprint {
            return modelURL
        }

        guard (try? Self.modelFileMatchesChecksum(at: modelURL, expectedChecksum: model.checksum)) == true else {
            verifiedModelFingerprints[model.modelIdentifier] = nil
            return nil
        }

        verifiedModelFingerprints[model.modelIdentifier] = fingerprint
        return modelURL
    }

    private func ensureLocalModelAvailable(
        modelIdentifier: String,
        filename: String,
        downloadURL: URL,
        checksum: ModelChecksum,
        maximumDownloadSizeBytes: Int64,
        progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> URL {
        let destinationURL = modelsDirectoryURL.appendingPathComponent(filename, isDirectory: false)

        if fileManager.fileExists(atPath: destinationURL.path) {
            if !Self.isRegularModelFile(at: destinationURL) {
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    throw ModelDownloadServiceError.invalidLocalModelFile
                }

                try? fileManager.removeItem(at: destinationURL)
            } else if try Self.modelFileMatchesChecksum(at: destinationURL, expectedChecksum: checksum) {
                progressHandler(.located(destinationURL))
                return destinationURL
            }

            try? fileManager.removeItem(at: destinationURL)
        }

        if let activeTask = activeDownloads[modelIdentifier] {
            return try await activeTask.value
        }

        let task = Task<URL, Error> { [fileManager, modelsDirectoryURL, session] in
            try Self.ensureModelsDirectoryExists(at: modelsDirectoryURL, using: fileManager)
            progressHandler(.starting(expectedBytes: nil))

            guard downloadURL.scheme?.lowercased() == "https" else {
                throw ModelDownloadServiceError.untrustedDownloadURL
            }

            let temporaryURL = destinationURL.appendingPathExtension("download")
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            var shouldKeepTemporaryFile = false
            defer {
                if !shouldKeepTemporaryFile {
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }

            let (bytes, response) = try await session.bytes(from: downloadURL)

            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                throw ModelDownloadServiceError.invalidServerResponse
            }
            guard httpResponse.url?.scheme?.lowercased() == "https" else {
                throw ModelDownloadServiceError.untrustedDownloadURL
            }

            let expectedLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            if let expectedLength, expectedLength > maximumDownloadSizeBytes {
                throw ModelDownloadServiceError.downloadTooLarge
            }

            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            ) else {
                throw ModelDownloadServiceError.couldNotCreateModelFile
            }

            let outputHandle = try FileHandle(forWritingTo: temporaryURL)
            defer {
                try? outputHandle.close()
            }

            var bytesWritten: Int64 = 0
            var chunkBuffer = Data()
            chunkBuffer.reserveCapacity(64 * 1024)

            for try await byte in bytes {
                chunkBuffer.append(byte)
                if bytesWritten + Int64(chunkBuffer.count) > maximumDownloadSizeBytes {
                    throw ModelDownloadServiceError.downloadTooLarge
                }

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

            try Task.checkCancellation()
            try outputHandle.synchronize()
            try outputHandle.close()

            guard try Self.modelFileMatchesChecksum(at: temporaryURL, expectedChecksum: checksum) else {
                try? fileManager.removeItem(at: temporaryURL)
                throw ModelDownloadServiceError.checksumMismatch
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    throw ModelDownloadServiceError.invalidLocalModelFile
                }

                try fileManager.removeItem(at: destinationURL)
            }

            try Task.checkCancellation()
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            shouldKeepTemporaryFile = true
            progressHandler(.finished(destinationURL))
            return destinationURL
        }

        activeDownloads[modelIdentifier] = task

        do {
            let destinationURL = try await task.value
            activeDownloads[modelIdentifier] = nil
            verifiedModelFingerprints[modelIdentifier] = nil
            return destinationURL
        } catch {
            activeDownloads[modelIdentifier] = nil
            // URLSession reports cancellation as URLError.cancelled. Keep the
            // app's cancellation path separate from genuine download failures.
            if task.isCancelled { throw CancellationError() }
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
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )

            let resourceValues = try directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
                throw ModelDownloadServiceError.couldNotCreateModelsDirectory
            }

            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw ModelDownloadServiceError.couldNotCreateModelsDirectory
        }
    }

    nonisolated private static func isRegularModelDirectory(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    nonisolated private static func isRegularModelFile(at fileURL: URL) -> Bool {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }

        return resourceValues.isRegularFile == true && resourceValues.isSymbolicLink != true
    }

    nonisolated private static func isValidEncoderDirectory(at directoryURL: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let modelURL = directoryURL.appendingPathComponent("model.mil", isDirectory: false)
        return isRegularModelFile(at: modelURL)
    }

    nonisolated private static func directoryByteCount(at directoryURL: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }

        var totalByteCount: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            totalByteCount += Int64(resourceValues.fileSize ?? 0)
        }

        return totalByteCount
    }

    private func extractZip(at zipURL: URL, toDirectory directoryURL: URL, modelIdentifier: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipURL.path, directoryURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.qualityOfService = .utility
            process.terminationHandler = { [weak self] process in
                guard let self else {
                    return
                }

                Task {
                    await self.completeExtraction(of: process, modelIdentifier: modelIdentifier, continuation: continuation)
                }
            }

            activeExtractions[modelIdentifier] = process

            do {
                try process.run()
            } catch {
                activeExtractions[modelIdentifier] = nil
                continuation.resume(throwing: ModelDownloadServiceError.encoderExtractionFailed)
            }
        }
    }

    private func completeExtraction(
        of process: Process,
        modelIdentifier: String,
        continuation: CheckedContinuation<Void, Error>
    ) {
        let wasCancelled = activeExtractions.removeValue(forKey: modelIdentifier) == nil

        if wasCancelled {
            continuation.resume(throwing: CancellationError())
        } else if process.terminationStatus == 0 {
            continuation.resume()
        } else {
            continuation.resume(throwing: ModelDownloadServiceError.encoderExtractionFailed)
        }
    }

    nonisolated private static func fingerprint(at fileURL: URL, expectedChecksum: ModelChecksum) -> VerifiedModelFingerprint? {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let byteCount = resourceValues.fileSize,
              let modificationDate = resourceValues.contentModificationDate else {
            return nil
        }

        return VerifiedModelFingerprint(
            byteCount: Int64(byteCount),
            modificationDate: modificationDate,
            checksum: expectedChecksum
        )
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

    nonisolated private static func installedModelFiles(
        in directoryURL: URL,
        fileManager: FileManager
    ) -> [LocalModelFile] {
        let whisperFiles = WhisperModelDescriptor.allCases.compactMap {
            localModelFile(for: $0, category: .whisper, in: directoryURL, fileManager: fileManager)
        }

        var refinementFiles = RefinementModelDescriptor.storedModels.compactMap {
            localModelFile(for: $0, category: .refinement, in: directoryURL, fileManager: fileManager)
        }
        let retiredURL = directoryURL.appendingPathComponent(retiredRefinementDirectory, isDirectory: true)
        if isRegularModelDirectory(at: retiredURL) {
            refinementFiles.append(LocalModelFile(category: .refinement,
                modelIdentifier: retiredRefinementIdentifier, displayName: "Qwen3 0.6B (retired MLX download)",
                filename: retiredRefinementDirectory, fileURL: retiredURL,
                byteCount: directoryByteCount(at: retiredURL), isEnabled: false))
        }

        let encoderFiles = WhisperModelDescriptor.allCases.compactMap {
            encoderModelFile(for: $0, in: directoryURL, fileManager: fileManager)
        }

        return (whisperFiles + encoderFiles + refinementFiles).sorted {
            if $0.category.sortIndex != $1.category.sortIndex {
                return $0.category.sortIndex < $1.category.sortIndex
            }

            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    nonisolated private static func localModelFile<Model: LocalModelDescriptor>(
        for model: Model,
        category: LocalModelFile.Category,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> LocalModelFile? {
        let fileURL = directoryURL.appendingPathComponent(model.filename, isDirectory: false)
        var isDirectory = ObjCBool(false)

        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              isRegularModelFile(at: fileURL) else {
            return nil
        }

        return LocalModelFile(
            category: category,
            modelIdentifier: model.modelIdentifier,
            displayName: model.displayName,
            filename: model.filename,
            fileURL: fileURL,
            byteCount: byteCount(at: fileURL, fileManager: fileManager),
            isEnabled: true
        )
    }

    nonisolated private static func encoderModelFile(
        for model: WhisperModelDescriptor,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> LocalModelFile? {
        let activeURL = directoryURL.appendingPathComponent(model.encoderDirectoryName, isDirectory: true)
        if isValidEncoderDirectory(at: activeURL) {
            return LocalModelFile(
                category: .whisperEncoder,
                modelIdentifier: model.encoderModelIdentifier,
                displayName: "\(model.displayName) Encoder",
                filename: model.encoderDirectoryName,
                fileURL: activeURL,
                byteCount: directoryByteCount(at: activeURL),
                isEnabled: true
            )
        }

        let disabledURL = directoryURL.appendingPathComponent(model.encoderDisabledDirectoryName, isDirectory: true)
        guard isValidEncoderDirectory(at: disabledURL) else {
            return nil
        }

        return LocalModelFile(
            category: .whisperEncoder,
            modelIdentifier: model.encoderModelIdentifier,
            displayName: "\(model.displayName) Encoder",
            filename: model.encoderDisabledDirectoryName,
            fileURL: disabledURL,
            byteCount: directoryByteCount(at: disabledURL),
            isEnabled: false
        )
    }

    nonisolated private static func knownModelURL(
        for file: LocalModelFile,
        in directoryURL: URL
    ) -> URL? {
        switch file.category {
        case .whisper:
            guard let model = WhisperModelDescriptor.allCases.first(where: { $0.modelIdentifier == file.modelIdentifier }),
                  model.filename == file.filename else {
                return nil
            }

            return directoryURL.appendingPathComponent(model.filename, isDirectory: false)
        case .refinement:
            if file.modelIdentifier == retiredRefinementIdentifier, file.filename == retiredRefinementDirectory {
                return directoryURL.appendingPathComponent(retiredRefinementDirectory, isDirectory: true)
            }
            guard let model = RefinementModelDescriptor.storedModels.first(where: { $0.modelIdentifier == file.modelIdentifier }),
                  model.filename == file.filename else {
                return nil
            }

            return directoryURL.appendingPathComponent(model.filename, isDirectory: false)
        case .whisperEncoder:
            guard let model = WhisperModelDescriptor.allCases.first(where: { $0.encoderModelIdentifier == file.modelIdentifier }),
                  file.filename == model.encoderDirectoryName || file.filename == model.encoderDisabledDirectoryName else {
                return nil
            }

            return directoryURL.appendingPathComponent(file.filename, isDirectory: true)
        }
    }

    nonisolated private static func removeIncompleteDownloads(
        in directoryURL: URL,
        fileManager: FileManager
    ) -> Int64 {
        guard let itemURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var freedByteCount: Int64 = 0

        for itemURL in itemURLs where itemURL.pathExtension == "download" {
            freedByteCount += byteCount(at: itemURL, fileManager: fileManager)
            try? fileManager.removeItem(at: itemURL)
        }

        return freedByteCount
    }

    nonisolated private static func byteCount(at fileURL: URL, fileManager: FileManager) -> Int64 {
        guard let size = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber else {
            return 0
        }

        return size.int64Value
    }
}
