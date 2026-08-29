import Foundation

protocol SettingsStoreProtocol: AnyObject {
    var shouldShowMainWindowOnLaunch: Bool { get }
    var hasRequestedAccessibilityPermission: Bool { get }
    var automaticallyChecksForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    var cachedAvailableUpdate: AppRelease? { get }
    var globalShortcut: GlobalShortcutDescriptor { get }
    var recordingPlaybackBehavior: RecordingPlaybackBehavior { get }
    var whisperConfiguration: WhisperConfiguration { get }
    var refinementConfiguration: RefinementConfiguration { get }
    func markInitialWindowPresentationComplete()
    func markAccessibilityPermissionRequested()
    func saveAutomaticallyChecksForUpdates(_ isEnabled: Bool)
    func saveUpdateCheck(date: Date, availableUpdate: AppRelease?)
    func saveGlobalShortcut(_ shortcut: GlobalShortcutDescriptor)
    func saveRecordingPlaybackBehavior(_ behavior: RecordingPlaybackBehavior)
    func saveWhisperConfiguration(_ configuration: WhisperConfiguration)
    func saveRefinementConfiguration(_ configuration: RefinementConfiguration)
}

final class UserDefaultsSettingsStore: SettingsStoreProtocol {
    private enum Keys {
        static let hasPresentedInitialWindow = "app.hasPresentedInitialWindow"
        static let hasRequestedAccessibilityPermission = "permissions.hasRequestedAccessibilityPermission"
        static let automaticallyChecksForUpdates = "updates.automaticallyChecks"
        static let lastUpdateCheckDate = "updates.lastCheckDate"
        static let cachedAvailableUpdate = "updates.cachedAvailableRelease"
        static let globalShortcut = "hotkey.globalShortcut"
        static let recordingPlaybackBehavior = "audio.recordingPlaybackBehavior"
        static let whisperConfiguration = "whisper.configuration"
        static let refinementConfiguration = "refinement.configuration"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldShowMainWindowOnLaunch: Bool {
        !defaults.bool(forKey: Keys.hasPresentedInitialWindow)
    }

    var hasRequestedAccessibilityPermission: Bool {
        defaults.bool(forKey: Keys.hasRequestedAccessibilityPermission)
    }

    var automaticallyChecksForUpdates: Bool {
        if defaults.object(forKey: Keys.automaticallyChecksForUpdates) == nil {
            return Bundle.main.bundleIdentifier == "com.dictaflow"
        }

        return defaults.bool(forKey: Keys.automaticallyChecksForUpdates)
    }

    var lastUpdateCheckDate: Date? {
        defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date
    }

    var cachedAvailableUpdate: AppRelease? {
        guard let data = defaults.data(forKey: Keys.cachedAvailableUpdate) else {
            return nil
        }

        return try? JSONDecoder().decode(AppRelease.self, from: data)
    }

    var globalShortcut: GlobalShortcutDescriptor {
        guard
            let data = defaults.data(forKey: Keys.globalShortcut),
            let shortcut = try? JSONDecoder().decode(GlobalShortcutDescriptor.self, from: data),
            shortcut.isValid
        else {
            return .toggleDictation
        }

        return shortcut
    }

    var whisperConfiguration: WhisperConfiguration {
        guard let data = defaults.data(forKey: Keys.whisperConfiguration) else {
            return .default
        }

        return (try? JSONDecoder().decode(WhisperConfiguration.self, from: data)) ?? .default
    }

    var recordingPlaybackBehavior: RecordingPlaybackBehavior {
        guard
            let rawValue = defaults.string(forKey: Keys.recordingPlaybackBehavior),
            let behavior = RecordingPlaybackBehavior(rawValue: rawValue)
        else {
            return .default
        }

        return behavior
    }

    var refinementConfiguration: RefinementConfiguration {
        guard let data = defaults.data(forKey: Keys.refinementConfiguration) else {
            return .default
        }

        return (try? JSONDecoder().decode(RefinementConfiguration.self, from: data)) ?? .default
    }

    func markInitialWindowPresentationComplete() {
        defaults.set(true, forKey: Keys.hasPresentedInitialWindow)
    }

    func markAccessibilityPermissionRequested() {
        defaults.set(true, forKey: Keys.hasRequestedAccessibilityPermission)
    }

    func saveAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Keys.automaticallyChecksForUpdates)
    }

    func saveUpdateCheck(date: Date, availableUpdate: AppRelease?) {
        defaults.set(date, forKey: Keys.lastUpdateCheckDate)

        guard
            let availableUpdate,
            let data = try? JSONEncoder().encode(availableUpdate)
        else {
            defaults.removeObject(forKey: Keys.cachedAvailableUpdate)
            return
        }

        defaults.set(data, forKey: Keys.cachedAvailableUpdate)
    }

    func saveGlobalShortcut(_ shortcut: GlobalShortcutDescriptor) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }

        defaults.set(data, forKey: Keys.globalShortcut)
    }

    func saveRecordingPlaybackBehavior(_ behavior: RecordingPlaybackBehavior) {
        defaults.set(behavior.rawValue, forKey: Keys.recordingPlaybackBehavior)
    }

    func saveWhisperConfiguration(_ configuration: WhisperConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }

        defaults.set(data, forKey: Keys.whisperConfiguration)
    }

    func saveRefinementConfiguration(_ configuration: RefinementConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }

        defaults.set(data, forKey: Keys.refinementConfiguration)
    }
}
