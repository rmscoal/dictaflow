import Foundation

protocol LocalModelDescriptor: Hashable, Sendable {
    nonisolated var modelIdentifier: String { get }
    nonisolated var displayName: String { get }
    nonisolated var filename: String { get }
    nonisolated var downloadURL: URL { get }
    nonisolated var checksum: ModelChecksum { get }
}

struct LocalModelFile: Identifiable, Equatable, Sendable {
    enum Category: String, Sendable {
        case whisper
        case refinement

        nonisolated var title: String {
            switch self {
            case .whisper:
                return "Whisper"
            case .refinement:
                return "Refinement"
            }
        }

        nonisolated var sortIndex: Int {
            switch self {
            case .whisper:
                return 0
            case .refinement:
                return 1
            }
        }
    }

    let category: Category
    let modelIdentifier: String
    let displayName: String
    let filename: String
    let fileURL: URL
    let byteCount: Int64

    var id: String {
        modelIdentifier
    }
}
