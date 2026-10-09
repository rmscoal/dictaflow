import Foundation

nonisolated struct RefinementConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var model: RefinementModelDescriptor
    var mode: RefinementMode

    static let `default` = RefinementConfiguration(
        isEnabled: false,
        model: .recommendedDefault,
        mode: .smartCleanup
    )

    init(
        isEnabled: Bool,
        model: RefinementModelDescriptor,
        mode: RefinementMode
    ) {
        self.isEnabled = isEnabled
        self.model = model
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case model
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let savedModelName = try container.decode(String.self, forKey: .model)
        let savedModel = RefinementModelDescriptor(rawValue: savedModelName)
        if let savedModel, RefinementModelDescriptor.allCases.contains(savedModel) {
            self.model = savedModel
        } else {
            self.model = .qwen3Small
        }
        self.mode = try container.decode(RefinementMode.self, forKey: .mode)
    }
}
