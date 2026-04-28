import Foundation

protocol LocalModelDescriptor: Hashable, Sendable {
    nonisolated var modelIdentifier: String { get }
    nonisolated var displayName: String { get }
    nonisolated var filename: String { get }
    nonisolated var downloadURL: URL { get }
    nonisolated var checksum: ModelChecksum { get }
}
