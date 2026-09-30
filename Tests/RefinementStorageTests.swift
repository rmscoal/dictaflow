import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class RefinementStorageTests: XCTestCase {
    func testLegacyDownloadsRemainRecognizedForExplicitCleanup() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = RefinementModelDescriptor.qwen25OneAndHalfB
        let url = directory.appendingPathComponent(model.filename)
        try Data("legacy fixture".utf8).write(to: url)
        let service = WhisperModelDownloadService(modelsDirectoryURL: directory)
        let files = service.installedModelFiles()
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.modelIdentifier, model.modelIdentifier)
        XCTAssertFalse(RefinementModelDescriptor.allCases.contains(model))
        let deleted = try await service.deleteModelFiles([file])
        XCTAssertEqual(deleted, 14)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMLXBundleRequiresEveryFileAndValidChecksums() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = RefinementModelDescriptor.qwen3SmallMLX
        let bundle = directory.appendingPathComponent(model.filename)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let service = WhisperModelDownloadService(modelsDirectoryURL: directory)
        XCTAssertFalse(service.isRefinementModelPrepared(model))
        for file in MLXRefinementModelFile.files {
            try Data("invalid fixture".utf8).write(to: bundle.appendingPathComponent(file.filename))
        }
        XCTAssertTrue(service.isRefinementModelPrepared(model))
        let verified = await service.verifiedRefinementModelURL(for: model)
        XCTAssertNil(verified, "Present files must not bypass checksum verification")
        let partial = bundle.appendingPathComponent("model.safetensors.download")
        try Data([1, 2, 3]).write(to: partial)
        XCTAssertEqual(service.removeIncompleteDownloads(), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("config.json").path))
    }

    func testMLXBundleDoesNotFollowDirectorySymlinks() async throws {
        let directory = try makeDirectory()
        let externalDirectory = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: externalDirectory)
        }
        for file in MLXRefinementModelFile.files {
            try Data("fixture".utf8).write(to: externalDirectory.appendingPathComponent(file.filename))
        }
        let model = RefinementModelDescriptor.qwen3SmallMLX
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(model.filename),
            withDestinationURL: externalDirectory)
        let service = WhisperModelDownloadService(modelsDirectoryURL: directory)
        XCTAssertFalse(service.isRefinementModelPrepared(model))
        XCTAssertTrue(service.installedModelFiles().isEmpty)
        let verified = await service.verifiedRefinementModelURL(for: model)
        XCTAssertNil(verified)
    }

    func testCancelledMLXDownloadUsesCancellationInsteadOfFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = XCTestExpectation(description: "Model download started")
        ModelDownloadCancellationFixture.onStart = { started.fulfill() }
        defer { ModelDownloadCancellationFixture.onStart = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadCancellationFixture.self]
        let service = WhisperModelDownloadService(session: URLSession(configuration: configuration), modelsDirectoryURL: directory)
        let download = Task {
            try await service.ensureRefinementModelAvailable(.qwen3SmallMLX) { _ in }
        }
        await fulfillment(of: [started], timeout: 5)
        await service.cancelDownload(modelIdentifier: RefinementModelDescriptor.qwen3SmallMLX.modelIdentifier)
        do {
            _ = try await download.value
            XCTFail("A cancelled download must not finish successfully")
        } catch is CancellationError {
            XCTAssertFalse(service.isRefinementModelPrepared(.qwen3SmallMLX))
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class ModelDownloadCancellationFixture: URLProtocol {
    private static let lock = NSLock()
    private static var startHandler: (() -> Void)?

    static var onStart: (() -> Void)? {
        get { lock.withLock { startHandler } }
        set { lock.withLock { startHandler = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() {}
}
