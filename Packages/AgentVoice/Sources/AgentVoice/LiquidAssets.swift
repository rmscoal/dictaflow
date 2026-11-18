import CryptoKit
import Darwin
import Foundation

public struct LiquidAsset: Sendable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
    public var url: URL {
        URL(string: "https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/\(LiquidAssets.revision)/\(name)")!
    }
}

public enum LiquidDownloadEvent: Equatable, Sendable {
    case downloading(bytesWritten: Int64, totalBytes: Int64)
    case verifying
}

public protocol LiquidAssetDownloading: Sendable {
    func isReady() async throws -> Bool
    func download(progressHandler: @escaping @Sendable (LiquidDownloadEvent) -> Void) async throws
}

public actor LiquidAssets: LiquidAssetDownloading {
    public static let revision = "02355c1a141e464a064f2ab2c276638dbcb7f38a"
    public static let files = [
        LiquidAsset(name: "LFM3-Audio-2B-Q4_K_M.gguf", bytes: 1_099_626_016, sha256: "9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2"),
        LiquidAsset(name: "mmproj-LFM3-Audio-2B-Q8_0.gguf", bytes: 303_811_840, sha256: "2b6648b1fd48af16aa0877b0592b144d15070783673e038a379fdbc51d40e365")
    ]
    public nonisolated let directory: URL
    private let manifest: [LiquidAsset]
    private let session: URLSession
    private var downloadTask: Task<Void, Error>?

    public init(directory: URL) {
        self.directory = directory
        manifest = Self.files
        session = .shared
    }

    init(directory: URL, manifest: [LiquidAsset], session: URLSession) {
        self.directory = directory
        self.manifest = manifest
        self.session = session
    }

    public func isReady() throws -> Bool {
        for asset in manifest {
            guard try Self.verify(directory.appendingPathComponent(asset.name), asset: asset) else { return false }
        }
        return true
    }

    public func download(progressHandler: @escaping @Sendable (LiquidDownloadEvent) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        if let downloadTask { return try await downloadTask.value }
        let directory = directory
        let task = Task {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let totalBytes = manifest.reduce(Int64(0)) { $0 + $1.bytes }
            var completedBytes: Int64 = 0
            for asset in manifest {
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent(asset.name)
                progressHandler(.verifying)
                if (try? Self.verify(destination, asset: asset)) == true {
                    completedBytes += asset.bytes
                    progressHandler(.downloading(bytesWritten: completedBytes, totalBytes: totalBytes))
                    continue
                }
                try Task.checkCancellation()
                let offset = completedBytes
                progressHandler(.downloading(bytesWritten: offset, totalBytes: totalBytes))
                let temporary = directory.appendingPathComponent(UUID().uuidString + ".download")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let delegate = LiquidDownloadDelegate(temporary: temporary, configuration: session.configuration) { bytesWritten in
                    progressHandler(.downloading(bytesWritten: offset + min(bytesWritten, asset.bytes), totalBytes: totalBytes))
                }
                var request = URLRequest(url: asset.url); request.timeoutInterval = 60 * 30
                let response = try await delegate.download(request)
                try Task.checkCancellation()
                progressHandler(.verifying)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      try Self.verify(temporary, asset: asset) else { throw VoiceError.unavailable("Liquid model verification failed. Try downloading it again.") }
                try Task.checkCancellation()
                try Self.installVerifiedDownload(temporary, at: destination)
                completedBytes += asset.bytes
                progressHandler(.downloading(bytesWritten: completedBytes, totalBytes: totalBytes))
            }
            try Task.checkCancellation()
        }
        downloadTask = task
        defer { downloadTask = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Installs an already checksum-verified download, removing the staging file on any failure.
    static func installVerifiedDownload(_ temporary: URL, at destination: URL) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".download")
        let files = FileManager.default
        defer {
            if files.fileExists(atPath: staging.path) {
                do { try files.removeItem(at: staging) }
                catch {
                    try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                    try? files.removeItem(at: staging)
                }
            }
        }
        try files.moveItem(at: temporary, to: staging)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        // Both paths are on the same volume. Renaming the staged file does
        // not require opening the old one or copying its metadata.
        guard Darwin.rename(staging.path, destination.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            if code == .EISDIR || code == .ENOTDIR {
                throw VoiceError.unavailable("Move the item named \(destination.lastPathComponent) out of the Liquid models folder, then retry the download.")
            }
            throw POSIXError(code)
        }
    }

    private static func verify(_ url: URL, asset: LiquidAsset) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == asset.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}

/// URLSession writes to disk and reports transfer progress without buffering model data in memory.
private final class LiquidDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let temporary: URL
    private let configuration: URLSessionConfiguration
    private let progressHandler: @Sendable (Int64) -> Void
    // Cancellation can arrive before the session starts; callbacks run on URLSession's queue.
    private let lock = NSLock()
    private var isCancelled = false
    private var session: URLSession?
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var result: Result<URLResponse, Error>?

    init(temporary: URL, configuration: URLSessionConfiguration,
         progressHandler: @escaping @Sendable (Int64) -> Void) {
        self.temporary = temporary
        self.configuration = configuration
        self.progressHandler = progressHandler
    }

    func download(_ request: URLRequest) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                // Use delegate-based tasks: completion-handler/async download tasks do
                // not deliver the download delegate's byte-progress callbacks.
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            let session = self.lock.withLock {
                self.isCancelled = true
                return self.session
            }
            session?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result = Result {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            // URLSession deletes location when this callback returns. Keep it for verification.
            try FileManager.default.moveItem(at: location, to: temporary)
            return response
        }
        lock.withLock { self.result = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result) = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            self.session = nil
            let result: Result<URLResponse, Error> = error.map { .failure($0) }
                ?? self.result ?? .failure(URLError(.badServerResponse))
            return (continuation, result)
        }
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
