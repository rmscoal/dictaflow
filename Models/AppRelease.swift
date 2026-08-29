import Foundation

nonisolated struct AppVersion: Codable, Comparable, Hashable, Sendable {
    private let components: [Int]

    init?(_ value: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionValue: Substring

        if trimmedValue.lowercased().hasPrefix("v") {
            versionValue = trimmedValue.dropFirst()
        } else {
            versionValue = Substring(trimmedValue)
        }

        let componentStrings = versionValue.split(separator: ".", omittingEmptySubsequences: false)
        guard !componentStrings.isEmpty else {
            return nil
        }

        var parsedComponents: [Int] = []
        parsedComponents.reserveCapacity(componentStrings.count)

        for componentString in componentStrings {
            guard
                !componentString.isEmpty,
                componentString.allSatisfy({ $0.isNumber }),
                let component = Int(componentString)
            else {
                return nil
            }

            parsedComponents.append(component)
        }

        components = parsedComponents
    }

    var displayString: String {
        components.map(String.init).joined(separator: ".")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        guard let version = AppVersion(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a numeric application version."
            )
        }

        self = version
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(displayString)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)

        for index in 0..<componentCount {
            let lhsComponent = index < lhs.components.count ? lhs.components[index] : 0
            let rhsComponent = index < rhs.components.count ? rhs.components[index] : 0

            if lhsComponent != rhsComponent {
                return lhsComponent < rhsComponent
            }
        }

        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var normalizedComponents = components
        while normalizedComponents.count > 1, normalizedComponents.last == 0 {
            normalizedComponents.removeLast()
        }

        hasher.combine(normalizedComponents)
    }
}

nonisolated struct AppRelease: Codable, Equatable, Sendable {
    let version: AppVersion
    let releasePageURL: URL

    var hasTrustedReleasePageURL: Bool {
        releasePageURL.scheme?.lowercased() == "https"
            && releasePageURL.host?.lowercased() == "github.com"
            && releasePageURL.path.lowercased().hasPrefix("/rmscoal/dictaflow/releases/")
    }
}
