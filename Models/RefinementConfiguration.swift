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
}
