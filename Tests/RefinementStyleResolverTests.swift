import Foundation
import XCTest
@testable import DictaFlow_Dev

final class RefinementStyleResolverTests: XCTestCase {
    func testExactMatchingFallbackDisabledAndDIY() {
        var configuration = RefinementConfiguration(isEnabled: true, model: .recommendedDefault,
            mode: .professionalFormal, appStyleRules: ["com.example.Editor": .technicalEngineering, "com.example.DIY": .diy])
        XCTAssertEqual(RefinementStyleResolver.effectiveMode(for: "com.example.Editor", in: configuration),
            .init(mode: .technicalEngineering, source: .rule))
        XCTAssertEqual(RefinementStyleResolver.effectiveMode(for: "com.example.DIY", in: configuration).mode, .diy)
        for id in [nil, "", "com.example.editor", "com.example.Editor.helper", "unknown"] {
            XCTAssertEqual(RefinementStyleResolver.effectiveMode(for: id, in: configuration),
                .init(mode: .professionalFormal, source: .default))
        }
        configuration.perAppStylesEnabled = false
        XCTAssertEqual(RefinementStyleResolver.effectiveMode(for: "com.example.Editor", in: configuration),
            .init(mode: .professionalFormal, source: .default))
    }

    func testMoveRemoveAndPreferenceRoundTrip() throws {
        var configuration = RefinementConfiguration.default
        configuration.writingStyleVersion = 2
        configuration.appStyleRules["com.example.Editor"] = .casualMessaging
        configuration.appStyleRules["com.example.Editor"] = .technicalEngineering
        XCTAssertEqual(configuration.appStyleRules.count, 1)
        let decoded = try JSONDecoder().decode(RefinementConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
        configuration.appStyleRules.removeValue(forKey: "com.example.Editor")
        XCTAssertEqual(RefinementStyleResolver.effectiveMode(for: "com.example.Editor", in: configuration).mode, configuration.mode)
    }

    func testStarterMigrationPreservesChoicesAndNeverRestoresRemovedRules() {
        var configuration = RefinementConfiguration(isEnabled: true, model: .recommendedDefault,
            mode: .diy, perAppStylesEnabled: false, appStyleRules: ["editor": .professionalFormal])
        configuration.migrateAppStyles(installedStarterRules: ["editor": .technicalEngineering, "chat": .casualMessaging])
        XCTAssertEqual(configuration.mode, .diy)
        XCTAssertFalse(configuration.perAppStylesEnabled)
        XCTAssertEqual(configuration.appStyleRules["editor"], .professionalFormal)
        XCTAssertEqual(configuration.appStyleRules["chat"], .casualMessaging)
        XCTAssertEqual(configuration.writingStyleVersion, 2)
        configuration.appStyleRules.removeValue(forKey: "chat")
        configuration.migrateAppStyles(installedStarterRules: ["chat": .casualMessaging])
        XCTAssertNil(configuration.appStyleRules["chat"])
    }

    func testOldPreferencesKeepDefaultAndMigrationVersion() throws {
        for version in ["", ",\"writingStyleVersion\":1"] {
            let data = Data("{\"isEnabled\":true,\"model\":\"qwen3Small\",\"mode\":\"casualMessaging\"\(version)}".utf8)
            let configuration = try JSONDecoder().decode(RefinementConfiguration.self, from: data)
            XCTAssertEqual(configuration.mode, .casualMessaging)
            XCTAssertTrue(configuration.isEnabled)
            XCTAssertTrue(configuration.appStyleRules.isEmpty)
            XCTAssertEqual(configuration.writingStyleVersion, version.isEmpty ? 0 : 1)
        }
    }
}
