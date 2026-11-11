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

public actor LiquidAssets {
    public static let revision = "02355c1a141e464a064f2ab2c276638dbcb7f38a"
    public static let files = [
        LiquidAsset(name: "LFM3-Audio-2B-Q4_K_M.gguf", bytes: 1_099_626_016, sha256: "9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2"),
        LiquidAsset(name: "mmproj-LFM3-Audio-2B-Q8_0.gguf", bytes: 303_811_840, sha256: "2b6648b1fd48af16aa0877b0592b144d15070783673e038a379fdbc51d40e365")
    ]
    public nonisolated let directory: URL
    private var downloadTask: Task<Void, Error>?

    public init(directory: URL) { self.directory = directory }

    public func isReady() throws -> Bool {
        for asset in Self.files {
            guard try Self.verify(directory.appendingPathComponent(asset.name), asset: asset) else { return false }
        }
        return true
    }

    public func download() async throws {
        if let downloadTask { return try await downloadTask.value }
        let directory = directory
        let task = Task {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for asset in Self.files {
                let destination = directory.appendingPathComponent(asset.name)
                if (try? Self.verify(destination, asset: asset)) == true { continue }
                var request = URLRequest(url: asset.url); request.timeoutInterval = 60 * 30
                let (temporary, response) = try await URLSession.shared.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      try Self.verify(temporary, asset: asset) else { throw VoiceError.unavailable("Liquid model verification failed. Try downloading it again.") }
                try Self.installVerifiedDownload(temporary, at: destination)
            }
        }
        downloadTask = task
        defer { downloadTask = nil }
        try await task.value
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
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}
