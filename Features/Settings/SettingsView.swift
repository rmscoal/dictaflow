import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        EmberPage {
            EmberPageHeading(title: "Settings")
            HStack(spacing: 3) {
                ForEach(SettingsCategory.allCases) { category in
                    Button { appState.settingsCategory = category } label: {
                        Text(category.title).font(.system(size: 12))
                            .frame(minWidth: 82).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(appState.settingsCategory == category ? AppTheme.tileFill : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-\(category.rawValue)")
                    .accessibilityAddTraits(appState.settingsCategory == category ? .isSelected : [])
                }
            }
            .padding(3).background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border, lineWidth: 1) }
            .padding(.bottom, 26)
            .accessibilityElement(children: .contain).accessibilityLabel("Settings categories")

            switch appState.settingsCategory {
            case .general: GeneralSettingsView(appState: appState)
            case .appearance:
                AppearanceSettingsView(appearance: Binding(get: { appState.appAppearance }, set: { appState.updateAppAppearance($0) }))
            case .permissions: PermissionsSettingsView(appState: appState)
            }
        }
    }
}
