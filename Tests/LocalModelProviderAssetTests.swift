import Foundation
import XCTest
@testable import DictaFlow_Dev

final class LocalModelProviderAssetTests: XCTestCase {
    private func makeFile(category: LocalModelFile.Category, modelIdentifier: String) -> LocalModelFile {
        LocalModelFile(
            category: category,
            modelIdentifier: modelIdentifier,
            displayName: "Fixture",
            filename: "fixture.bin",
            fileURL: URL(fileURLWithPath: "/tmp/fixture.bin"),
            byteCount: 1,
            isEnabled: true
        )
    }

    func testWhisperFileUsesOpenAIProviderAsset() {
        let file = makeFile(category: .whisper, modelIdentifier: WhisperModelDescriptor.largeV3Turbo.modelIdentifier)
        XCTAssertEqual(file.providerAssetName, "provider-openai")
    }

    func testWhisperEncoderFileUsesOpenAIProviderAsset() {
        let file = makeFile(
            category: .whisperEncoder,
            modelIdentifier: WhisperModelDescriptor.largeV3Turbo.encoderModelIdentifier
        )
        XCTAssertEqual(file.providerAssetName, "provider-openai")
    }

    func testRefinementFilesResolveProviderAssets() {
        XCTAssertEqual(
            makeFile(category: .refinement, modelIdentifier: RefinementModelDescriptor.qwen3FourB2507.modelIdentifier).providerAssetName,
            "provider-qwen"
        )
        XCTAssertEqual(
            makeFile(category: .refinement, modelIdentifier: RefinementModelDescriptor.gemma4E2B.modelIdentifier).providerAssetName,
            "provider-google"
        )
        XCTAssertEqual(
            makeFile(category: .refinement, modelIdentifier: RefinementModelDescriptor.phi4Mini.modelIdentifier).providerAssetName,
            "provider-microsoft"
        )
    }

    func testRefinementFileWithoutProviderResolvesNil() {
        let legacy = makeFile(
            category: .refinement,
            modelIdentifier: RefinementModelDescriptor.llama32ThreeB.modelIdentifier
        )
        XCTAssertNil(legacy.providerAssetName)

        let unknown = makeFile(category: .refinement, modelIdentifier: "refinement.unknown-model")
        XCTAssertNil(unknown.providerAssetName)
    }
}
