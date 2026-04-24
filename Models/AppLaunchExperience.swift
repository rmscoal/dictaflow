import Foundation

enum AppLaunchExperience {
    case firstLaunch
    case returningUser

    var headline: String {
        switch self {
        case .firstLaunch:
            return "Welcome. This first run opens the main utility window automatically."
        case .returningUser:
            return "DictaFlow is configured to launch quietly into the menu bar."
        }
    }

    var summary: String {
        switch self {
        case .firstLaunch:
            return "This is the first launch, so DictaFlow opens its main window once before switching to menu-bar-first behavior."
        case .returningUser:
            return "This is a returning launch, so DictaFlow stays in the menu bar until you open the main window manually."
        }
    }
}
