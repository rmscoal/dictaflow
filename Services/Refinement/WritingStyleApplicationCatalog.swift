import AppKit

struct WritingStyleApplication: Identifiable {
    let id: String
    let name: String
    let url: URL?

    var icon: NSImage {
        url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
}

@MainActor
protocol WritingStyleApplicationCatalogProtocol {
    func application(bundleID: String) -> WritingStyleApplication
    func runningApplications() -> [WritingStyleApplication]
    func suggestedApplications() -> [WritingStyleApplication]
}

@MainActor
struct WritingStyleApplicationCatalog: WritingStyleApplicationCatalogProtocol {
    static let starterRules: [String: RefinementMode] = [
        "com.apple.Terminal": .technicalEngineering,
        "com.openai.chat": .technicalEngineering,
        "com.openai.codex": .technicalEngineering,
        "com.anthropic.claude": .technicalEngineering,
        "com.anthropic.claudefordesktop": .technicalEngineering,
        "com.googlecode.iterm2": .technicalEngineering,
        "com.mitchellh.ghostty": .technicalEngineering,
        "com.tinyspeck.slackmacgap": .casualMessaging,
        "net.whatsapp.WhatsApp": .casualMessaging,
        "com.hnc.Discord": .casualMessaging,
        "com.apple.MobileSMS": .casualMessaging
    ]

    func application(bundleID: String) -> WritingStyleApplication {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return WritingStyleApplication(id: bundleID,
            name: url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID,
            url: url)
    }

    func runningApplications() -> [WritingStyleApplication] {
        let ids = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }.compactMap(\.bundleIdentifier))
        return ids.map { application(bundleID: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func suggestedApplications() -> [WritingStyleApplication] {
        let ids = Set(Self.starterRules.keys).union(["com.apple.Notes", "com.apple.Safari", "com.apple.Mail", "com.apple.Xcode", "com.microsoft.VSCode"])
        return ids.map { application(bundleID: $0) }.filter { $0.url != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
