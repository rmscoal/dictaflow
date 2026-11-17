import Foundation
import Logging
import MCP

/// Temporary compatibility boundary for upstream Swift MCP SDK issue #287.
/// The SDK decodes experimental client capabilities as strings. We do not implement
/// any such extensions, so ignore unsupported values rather than failing initialization.
/// All other message fields and all non-initialization messages pass through unchanged.
public actor InitializationCompatibilityTransport: Transport {
    public nonisolated let logger = Logger(label: "com.dictaflow.mcp.transport") { _ in SwiftLogNoOpLogHandler() }
    private let base: any Transport

    public init(base: any Transport) { self.base = base }

    public func connect() async throws { try await base.connect() }
    public func disconnect() async { await base.disconnect() }
    public func send(_ data: Data) async throws { try await base.send(data) }

    public func receive() -> AsyncThrowingStream<Data, any Error> {
        let base = base
        return AsyncThrowingStream { continuation in
            let forwarding = Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(Self.compatibleInitialization(data))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }

    public nonisolated static func compatibleInitialization(_ data: Data) -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["method"] as? String == "initialize",
              var parameters = message["params"] as? [String: Any],
              var capabilities = parameters["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any] else { return data }
        let supportedByDecoder = experimental.filter { $0.value is String }
        guard supportedByDecoder.count != experimental.count else { return data }
        capabilities["experimental"] = supportedByDecoder
        parameters["capabilities"] = capabilities
        message["params"] = parameters
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}
