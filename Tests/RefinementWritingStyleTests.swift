import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class RefinementWritingStyleTests: XCTestCase {
    func testPresetsComposeSavedInstructionsAndLanguage() {
        for mode in RefinementMode.allCases where mode != .diy {
            XCTAssertNotNil(Bundle.main.url(forResource: mode.rawValue, withExtension: "md"), "Built-in prompt must ship in the app")
            let source = RefinementPromptTemplate.template(for: mode, additionalInstructions: "Keep paragraphs short.", diyPrompt: "Ignored DIY")
            let rendered = RefinementPromptTemplate.renderedInstructions(from: source, whisperTaskMode: .translateToEnglish)
            XCTAssertTrue(rendered.contains("Keep paragraphs short."))
            XCTAssertTrue(rendered.contains("Output English."))
            XCTAssertFalse(rendered.contains("Ignored DIY"))
            XCTAssertFalse(rendered.contains("{{languageInstruction}}"))
        }
        let diy = RefinementPromptTemplate.template(for: .diy, additionalInstructions: "Ignored addition", diyPrompt: "# My rules\nKeep code.")
        XCTAssertEqual(diy, "# My rules\nKeep code.")
        XCTAssertTrue(RefinementPromptTemplate.renderedInstructions(from: diy, whisperTaskMode: .transcribe).hasSuffix("Preserve the original language."))
    }

    func testPrivateStorePersistsIndependentPresetsAndMarkdown() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileRefinementPromptStore(directoryURL: url)
        let diy = "# Instructions\n- **Keep** `code`\n\n```swift\nlet value = 1\n```"
        try store.savePromptTemplate(diy)
        try store.savePresetInstructions(["smartCleanup": "Keep my voice.", "casualMessaging": "No emojis."])
        let reopened = FileRefinementPromptStore(directoryURL: url)
        XCTAssertEqual(reopened.promptTemplate(), diy)
        XCTAssertEqual(try reopened.presetInstructions()["casualMessaging"], "No emojis.")
        try reopened.savePresetInstructions(["smartCleanup": ""])
        XCTAssertEqual(try reopened.presetInstructions(), ["smartCleanup": ""])
        XCTAssertEqual(reopened.promptTemplate(), diy)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("preset-instructions.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPresetStoreRejectsSymlinkAndCorruption() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("preset-instructions.json")
        let target = url.appendingPathComponent("target")
        try Data("not JSON".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let store = FileRefinementPromptStore(directoryURL: url)
        XCTAssertThrowsError(try store.presetInstructions())
        XCTAssertThrowsError(try store.savePresetInstructions([:]))
        try FileManager.default.removeItem(at: file)
        try Data("not JSON".utf8).write(to: file)
        XCTAssertThrowsError(try store.presetInstructions())
        XCTAssertThrowsError(try store.savePresetInstructions(["smartCleanup": "Replacement"]))
        XCTAssertEqual(try Data(contentsOf: file), Data("not JSON".utf8))
    }

    func testSplittingPreservesEverySourceCharacterAndOrder() throws {
        let text = String(repeating: "Review `auth_token`. Preserve every constraint.\n\n", count: 150)
        let split = try XCTUnwrap(RefinementInference.splitNearMiddle(text))
        XCTAssertEqual(split.0 + split.1, text)
        XCTAssertLessThan(split.0.count, text.count)
        XCTAssertLessThan(split.1.count, text.count)
        XCTAssertNil(RefinementInference.splitNearMiddle("Short text"))
    }

    func testCatalogRoundTripsAndUsesPinnedArtifacts() throws {
        for model in RefinementModelDescriptor.allCases {
            let configuration = RefinementConfiguration(isEnabled: true, model: model, mode: .technicalEngineering)
            let decoded = try JSONDecoder().decode(RefinementConfiguration.self, from: JSONEncoder().encode(configuration))
            XCTAssertEqual(decoded, configuration)
            XCTAssertFalse(model.downloadURL.path.contains("/main/"))
            XCTAssertGreaterThan(model.approximateDiskSizeBytes, 0)
        }
    }
}
