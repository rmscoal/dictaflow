import Foundation

struct RefinementConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var model: RefinementModelDescriptor
    var mode: RefinementMode
    var promptStyle: RefinementPromptStyle

    static let `default` = RefinementConfiguration(
        isEnabled: false,
        model: .recommendedDefault,
        mode: .smartCleanup,
        promptStyle: .automatic
    )

    init(
        isEnabled: Bool,
        model: RefinementModelDescriptor,
        mode: RefinementMode,
        promptStyle: RefinementPromptStyle = .automatic
    ) {
        self.isEnabled = isEnabled
        self.model = model
        self.mode = mode
        self.promptStyle = promptStyle
    }

    nonisolated var resolvedPromptProfile: RefinementPromptProfile {
        promptStyle.resolvedProfile(for: model)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case model
        case mode
        case promptStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        self.model = try container.decode(RefinementModelDescriptor.self, forKey: .model)
        self.mode = try container.decode(RefinementMode.self, forKey: .mode)
        self.promptStyle = try container.decodeIfPresent(RefinementPromptStyle.self, forKey: .promptStyle) ?? .automatic
    }
}
