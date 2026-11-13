@testable import AgentVoice
import Foundation
import Testing

struct LiquidAssetsTests {
    @Test func installingVerifiedDownloadReplacesUnreadableFile() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("model")
        try Data("old".utf8).write(to: destination)
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destination.path)
        let download = directory.appendingPathComponent("verified")
        let verified = Data("new".utf8)
        try verified.write(to: download)

        try LiquidAssets.installVerifiedDownload(download, at: destination)

        #expect(try Data(contentsOf: destination) == verified)
        let metadata = try files.attributesOfItem(atPath: destination.path)
        #expect((metadata[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try files.contentsOfDirectory(atPath: directory.path) == ["model"])
    }
}
