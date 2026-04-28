import Foundation

protocol SettingsStoreProtocol: AnyObject {
    var shouldShowMainWindowOnLaunch: Bool { get }
    var hasRequestedAccessibilityPermission: Bool { get }
    var whisperConfiguration: WhisperConfiguration { get }
    var refinementConfiguration: RefinementConfiguration { get }
    func markInitialWindowPresentationComplete()
    func markAccessibilityPermissionRequested()
    func saveWhisperConfiguration(_ configuration: WhisperConfiguration)
    func saveRefinementConfiguration(_ configuration: RefinementConfiguration)
}

final class UserDefaultsSettingsStore: SettingsStoreProtocol {
    private enum Keys {
        static let hasPresentedInitialWindow = "app.hasPresentedInitialWindow"
        static let hasRequestedAccessibilityPermission = "permissions.hasRequestedAccessibilityPermission"
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

    var whisperConfiguration: WhisperConfiguration {
        guard let data = defaults.data(forKey: Keys.whisperConfiguration) else {
            return .default
        }

        return (try? JSONDecoder().decode(WhisperConfiguration.self, from: data)) ?? .default
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
