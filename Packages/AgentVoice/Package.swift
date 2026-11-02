// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AgentVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentVoice", targets: ["AgentVoice"]),
        .executable(name: "dictaflow-mcp", targets: ["DictaFlowMCP"]),
        .executable(name: "dictaflow-audio-check", targets: ["AudioCheck"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "AgentVoice", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "AgentVoiceMCP", dependencies: ["AgentVoice", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
        .executableTarget(name: "DictaFlowMCP", dependencies: ["AgentVoiceMCP"]),
        .executableTarget(name: "AudioCheck", dependencies: ["AgentVoice"]),
        .testTarget(name: "AgentVoiceTests", dependencies: ["AgentVoice", "AgentVoiceMCP", .product(name: "MCP", package: "swift-sdk")])
    ]
)
