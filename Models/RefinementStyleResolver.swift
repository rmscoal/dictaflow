import Foundation

nonisolated enum RefinementStyleResolver {
    enum Source: Equatable { case rule, `default` }
    struct Resolution: Equatable {
        let mode: RefinementMode
        let source: Source
    }

    static func effectiveMode(for bundleID: String?, in configuration: RefinementConfiguration) -> Resolution {
        if configuration.perAppStylesEnabled, let bundleID, let mode = configuration.appStyleRules[bundleID] {
            return Resolution(mode: mode, source: .rule)
        }
        return Resolution(mode: configuration.mode, source: .default)
    }
}
