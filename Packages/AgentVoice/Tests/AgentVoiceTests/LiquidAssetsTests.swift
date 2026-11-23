@testable import AgentVoice
import Foundation
import CryptoKit
import Testing

struct LiquidAssetsTests {
    @Test func assetURLPreservesFilenameWithHash() {
        let asset = LiquidAsset(name: "model#2.gguf", bytes: 3, sha256: "")
        #expect(asset.url.lastPathComponent == asset.name)
        #expect(asset.url.fragment == nil)
        #expect(asset.url.absoluteString.hasSuffix("/\(LiquidAssets.revision)/model%232.gguf"))
    }

    @Test func downloadReportsCombinedProgressAndSkipsVerifiedFilesOnRetry() async throws {
        let fixture = try LiquidAssetDownloadFixture()
        defer { fixture.cleanup() }
        // An earlier attempt has already installed the first file.
        try LiquidAssetURLProtocol.first.write(to: fixture.directory.appendingPathComponent("first.gguf"))
        let (events, continuation) = AsyncStream.makeStream(of: LiquidDownloadEvent.self)
        try await fixture.assets.download { continuation.yield($0) }
        continuation.finish()
        var received: [LiquidDownloadEvent] = []
        for await event in events { received.append(event) }

        let firstBytes = Int64(LiquidAssetURLProtocol.first.count)
        let total = firstBytes + Int64(LiquidAssetURLProtocol.second.count)
        #expect(received.contains(.downloading(bytesWritten: firstBytes, totalBytes: total)))
        let verification = try #require(received.lastIndex(of: .verifying))
        // Transfer progress must arrive before verification, not only after installation.
        #expect(received[..<verification].contains { event in
            if case .downloading(let written, let expected) = event { return written > firstBytes && expected == total }
            return false
        })
        #expect(received.contains(.verifying))
        #expect(received.last == .downloading(bytesWritten: total, totalBytes: total))
        #expect(try await fixture.assets.isReady())
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("second.gguf")) == LiquidAssetURLProtocol.second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == ["first.gguf", "second.gguf"])
    }

    @Test func checksumFailureDoesNotInstallUnverifiedFile() async throws {
        let fixture = try LiquidAssetDownloadFixture(invalidChecksum: true)
        defer { fixture.cleanup() }
        await #expect(throws: (any Error).self) { try await fixture.assets.download() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        #expect(try await !fixture.assets.isReady())
    }

    @Test func cancellationStopsTransferWithoutInstallingPartialFile() async throws {
        let fixture = try LiquidAssetDownloadFixture(slow: true)
        defer { fixture.cleanup() }
        let (events, continuation) = AsyncStream.makeStream(of: LiquidDownloadEvent.self)
        let download = Task {
            defer { continuation.finish() }
            try await fixture.assets.download { continuation.yield($0) }
        }
        // A missing progress callback must fail promptly instead of hanging this regression test.
        let timeout = Task {
            try await Task.sleep(for: .seconds(3))
            download.cancel()
        }
        defer { timeout.cancel() }
        var sawTransferProgress = false
        for await event in events {
            if case .downloading(let bytes, _) = event, bytes > 0 {
                sawTransferProgress = true
                download.cancel()
                break
            }
        }
        await #expect(throws: (any Error).self) { try await download.value }
        #expect(sawTransferProgress)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test func installingVerifiedDownloadReplacesUnreadableFile() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("model")
        try Data("old".utf8).write(to: destination)
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destination.path)
        let download = directory.appendingPathComponent("verified")
        let verified = Data("new".utf8)
        try verified.write(to: download)

        try LiquidAssets.installVerifiedDownload(download, at: destination)

        #expect(try Data(contentsOf: destination) == verified)
        let metadata = try files.attributesOfItem(atPath: destination.path)
        #expect((metadata[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try files.contentsOfDirectory(atPath: directory.path) == ["model"])
    }
}

private struct LiquidAssetDownloadFixture {
    let directory: URL
    let session: URLSession
    let assets: LiquidAssets

    init(invalidChecksum: Bool = false, slow: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiquidAssetURLProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        session = URLSession(configuration: configuration)
        let manifest = [(slow ? "slow.gguf" : "first.gguf", LiquidAssetURLProtocol.first), ("second.gguf", LiquidAssetURLProtocol.second)].map { name, data in
            LiquidAsset(name: name, bytes: Int64(data.count), sha256: invalidChecksum ? "invalid" : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        assets = LiquidAssets(directory: directory, manifest: manifest, session: session)
    }

    func cleanup() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class LiquidAssetURLProtocol: URLProtocol, @unchecked Sendable {
    static let first = Data(repeating: 1, count: 256 * 1024)
    static let second = Data(repeating: 2, count: 128 * 1024)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let data = url.lastPathComponent == "second.gguf" ? Self.second : Self.first
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: url.lastPathComponent == "slow.gguf" ? data.prefix(data.count / 2) : data)
        if url.lastPathComponent != "slow.gguf" { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
