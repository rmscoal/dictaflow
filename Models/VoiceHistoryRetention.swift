import Foundation

/// Voice history retention, mirroring HistoryRetention for recordings.
/// Options are Off/7/14/30 days with a 30-day default, which preserves the
/// long-standing fixed voice behavior. The 500-interaction cap stays fixed
/// and is enforced separately in VoiceStore.
nonisolated enum VoiceHistoryRetention: Int, CaseIterable, Identifiable {
    case off = 0
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var id: Int { rawValue }
    var title: String { self == .off ? "Off" : "\(rawValue) days" }

    /// Age limit applied to retained interactions, or nil when Off.
    /// Off stops new voice history from being retained; existing entries
    /// keep the expiry they were stamped with.
    var retentionInterval: TimeInterval? {
        self == .off ? nil : TimeInterval(rawValue) * 86400
    }

    static let defaultsKey = "voice.historyRetentionDays"

    static func load(from defaults: UserDefaults = .standard) -> VoiceHistoryRetention {
        guard defaults.object(forKey: defaultsKey) != nil else { return .thirtyDays }
        return VoiceHistoryRetention(rawValue: defaults.integer(forKey: defaultsKey)) ?? .thirtyDays
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
