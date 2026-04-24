import Foundation

protocol SettingsStoreProtocol: AnyObject {
    var shouldShowMainWindowOnLaunch: Bool { get }
    func markInitialWindowPresentationComplete()
}

final class UserDefaultsSettingsStore: SettingsStoreProtocol {
    private enum Keys {
        static let hasPresentedInitialWindow = "app.hasPresentedInitialWindow"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldShowMainWindowOnLaunch: Bool {
        !defaults.bool(forKey: Keys.hasPresentedInitialWindow)
    }

    func markInitialWindowPresentationComplete() {
        defaults.set(true, forKey: Keys.hasPresentedInitialWindow)
    }
}
