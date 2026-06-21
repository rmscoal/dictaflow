import Foundation

struct RefinementConfiguration: Codable, Equatable {
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
        self.model = try container.decode(RefinementModelDescriptor.self, forKey: .model)
        self.mode = try container.decode(RefinementMode.self, forKey: .mode)
    }
}
