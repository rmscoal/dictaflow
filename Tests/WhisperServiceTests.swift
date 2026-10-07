import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class WhisperServiceTests: XCTestCase {
    func testBundledModelAndLicenseArePresentAndVerified() async throws {
        let url = try await WhisperCPPService().verifiedVADModelURL()
        XCTAssertEqual(url.lastPathComponent, "ggml-silero-v6.2.0.bin")
        XCTAssertEqual(try Data(contentsOf: url).count, 885_098)
        let licenseURL = try XCTUnwrap(Bundle.main.url(forResource: "silero-vad-LICENSE", withExtension: nil))
        XCTAssertTrue(try String(contentsOf: licenseURL, encoding: .utf8).contains("Silero Team"))
    }

    func testMissingModelPreventsPreparationAndTranscription() async throws {
        let service = WhisperCPPService(vadModelURL: nil)
        let unusedURL = URL(fileURLWithPath: "/unused")
        do {
            try await service.prepare(modelURL: unusedURL)
            XCTFail("Preparation must reject a missing VAD model")
        } catch {
            XCTAssertEqual(error as? WhisperServiceError, .missingVADModel)
        }
        for mode in [WhisperTaskMode.transcribe, .translateToEnglish] {
            var configuration = WhisperConfiguration.default
            configuration.taskMode = mode
            do {
                _ = try await service.transcribe(audioFileURL: unusedURL, modelURL: unusedURL, configuration: configuration)
                XCTFail("User transcription must never bypass a missing VAD model")
            } catch {
                XCTAssertEqual(error as? WhisperServiceError, .missingVADModel)
                XCTAssertTrue(error.localizedDescription.contains("Reinstall DictaFlow"))
            }
        }
    }

    func testCorruptModelIsRejectedAndVerificationCanRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt weights".utf8).write(to: url)
        let service = WhisperCPPService(vadModelURL: url)
        do {
            _ = try await service.verifiedVADModelURL()
            XCTFail("A checksum mismatch must fail")
        } catch {
            XCTAssertEqual(error as? WhisperServiceError, .invalidVADModel)
        }
        let bundledURL = try await WhisperCPPService().verifiedVADModelURL()
        try Data(contentsOf: bundledURL).write(to: url)
        let verifiedURL = try await service.verifiedVADModelURL()
        XCTAssertEqual(verifiedURL, url)
    }

    func testEncoderWarmupUsesItsDedicatedPathWithoutVAD() async {
        let service = WhisperCPPService(audioDecodingService: WarmupAudioDecoder(), vadModelURL: nil)
        let unusedURL = URL(fileURLWithPath: "/unused")
        do {
            try await service.warmUpEncoder(audioFileURL: unusedURL, modelURL: unusedURL, configuration: .default)
            XCTFail("The test decoder should stop warmup before native inference")
        } catch {
            XCTAssertTrue(error is WarmupAudioDecoder.ReachedDecoder)
        }
    }
}

private actor WarmupAudioDecoder: AudioDecodingServiceProtocol {
    struct ReachedDecoder: Error {}
    func decodePCMFloatSamples(from fileURL: URL) async throws -> [Float] {
        throw ReachedDecoder()
    }
}
