import Foundation

protocol SettingsStoreProtocol: AnyObject {
    var shouldShowMainWindowOnLaunch: Bool { get }
    var hasRequestedAccessibilityPermission: Bool { get }
    func markInitialWindowPresentationComplete()
    func markAccessibilityPermissionRequested()
}

final class UserDefaultsSettingsStore: SettingsStoreProtocol {
    private enum Keys {
        static let hasPresentedInitialWindow = "app.hasPresentedInitialWindow"
        static let hasRequestedAccessibilityPermission = "permissions.hasRequestedAccessibilityPermission"
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

    func markInitialWindowPresentationComplete() {
        defaults.set(true, forKey: Keys.hasPresentedInitialWindow)
    }

    func markAccessibilityPermissionRequested() {
        defaults.set(true, forKey: Keys.hasRequestedAccessibilityPermission)
    }
}
