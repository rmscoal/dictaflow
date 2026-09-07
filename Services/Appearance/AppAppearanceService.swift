import AppKit

@MainActor
protocol AppAppearanceApplying {
    func apply(_ appearance: AppAppearance)
}

@MainActor
struct SystemAppAppearanceService: AppAppearanceApplying {
    func apply(_ appearance: AppAppearance) {
        // A nil override lets all windows continue following macOS, including
        // system appearance changes while DictaFlow is running.
        switch appearance {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
