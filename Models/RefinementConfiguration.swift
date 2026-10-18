import Foundation

nonisolated struct RefinementConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var model: RefinementModelDescriptor
    // Version 1 preserves the existing prompt migration; app discovery completes version 2.
    var writingStyleVersion = 1
    var mode: RefinementMode
    var perAppStylesEnabled: Bool
    var appStyleRules: [String: RefinementMode]

    static let `default` = RefinementConfiguration(
        isEnabled: false,
        model: .recommendedDefault,
        mode: .smartCleanup
    )

    init(
        isEnabled: Bool,
        model: RefinementModelDescriptor,
        mode: RefinementMode,
        perAppStylesEnabled: Bool = true,
        appStyleRules: [String: RefinementMode] = [:]
    ) {
        self.isEnabled = isEnabled
        self.model = model
        self.mode = mode
        self.perAppStylesEnabled = perAppStylesEnabled
        self.appStyleRules = appStyleRules
    }

    mutating func migrateAppStyles(installedStarterRules: [String: RefinementMode]) {
        guard writingStyleVersion < 2 else { return }
        appStyleRules.merge(installedStarterRules) { existing, _ in existing }
        writingStyleVersion = 2
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, model, mode, writingStyleVersion, perAppStylesEnabled, appStyleRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let savedModelName = try container.decode(String.self, forKey: .model)
        let savedModel = RefinementModelDescriptor(rawValue: savedModelName)
        if savedModel == .llama32ThreeB {
            // Keep the retired selection visible instead of silently choosing another model.
            self.model = .llama32ThreeB
            self.isEnabled = false
        } else if let savedModel, RefinementModelDescriptor.allCases.contains(savedModel) {
            self.model = savedModel
        } else {
            self.model = .qwen3Small
        }
        self.mode = try container.decode(RefinementMode.self, forKey: .mode)
        self.perAppStylesEnabled = try container.decodeIfPresent(Bool.self, forKey: .perAppStylesEnabled) ?? true
        self.appStyleRules = try container.decodeIfPresent([String: RefinementMode].self, forKey: .appStyleRules) ?? [:]
        self.writingStyleVersion = try container.decodeIfPresent(Int.self, forKey: .writingStyleVersion) ?? 0
    }
}
