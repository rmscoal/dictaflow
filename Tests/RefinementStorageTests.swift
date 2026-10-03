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


    func testRetiredBundleRemainsAvailableForExplicitCleanup() async throws {
        let directory = try makeDirectory()
        let external = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: external)
        }
        let bundle = directory.appendingPathComponent("qwen3-0.6b-mlx-4bit")
        try FileManager.default.createSymbolicLink(at: bundle, withDestinationURL: external)
        let service = WhisperModelDownloadService(modelsDirectoryURL: directory)
        XCTAssertTrue(service.installedModelFiles().isEmpty, "Do not list external symlink targets")
        try FileManager.default.removeItem(at: bundle)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: bundle.appendingPathComponent("model.safetensors"))
        let file = try XCTUnwrap(service.installedModelFiles().first)
        XCTAssertFalse(file.isEnabled)
        let freed = try await service.deleteModelFiles([file])
        XCTAssertEqual(freed, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testStandardModelRequiresValidChecksum() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = RefinementModelDescriptor.qwen3Small
        try Data("invalid fixture".utf8).write(to: directory.appendingPathComponent(model.filename))
        let service = WhisperModelDownloadService(modelsDirectoryURL: directory)
        XCTAssertTrue(service.isRefinementModelPrepared(model))
        let verified = await service.verifiedRefinementModelURL(for: model)
        XCTAssertNil(verified)
    }

    func testCancelledRefinementDownloadUsesCancellationInsteadOfFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = XCTestExpectation(description: "Model download started")
        ModelDownloadCancellationFixture.onStart = { started.fulfill() }
        defer { ModelDownloadCancellationFixture.onStart = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadCancellationFixture.self]
        let service = WhisperModelDownloadService(session: URLSession(configuration: configuration), modelsDirectoryURL: directory)
        let download = Task {
            try await service.ensureRefinementModelAvailable(.qwen3Small) { _ in }
        }
        await fulfillment(of: [started], timeout: 5)
        await service.cancelDownload(modelIdentifier: RefinementModelDescriptor.qwen3Small.modelIdentifier)
        do {
            _ = try await download.value
            XCTFail("A cancelled download must not finish successfully")
        } catch is CancellationError {
            XCTAssertFalse(service.isRefinementModelPrepared(.qwen3Small))
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
