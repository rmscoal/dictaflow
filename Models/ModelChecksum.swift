import Foundation

enum ModelChecksum: Codable, Equatable, Hashable, Sendable {
    case sha1(String)
    case sha256(String)

    var value: String {
        switch self {
        case .sha1(let value), .sha256(let value):
            return value
        }
    }
}
