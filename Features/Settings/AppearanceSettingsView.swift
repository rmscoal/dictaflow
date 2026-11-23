import SwiftUI

struct AppearanceSettingsView: View {
    @Binding var appearance: AppAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberSectionHeading(title: "App appearance")
            HStack(spacing: 13) {
                ForEach([AppAppearance.light, .dark, .system]) { option in
                    Button { appearance = option } label: {
                        VStack(spacing: 10) {
                            AppearanceThumbnail(appearance: option).frame(height: 135)
                            HStack {
                                Text(option.title)
                                Spacer()
                                if appearance == option { Image(systemName: "checkmark") }
                            }
                            .font(.system(size: 13))
                        }
                        .padding(10).frame(maxWidth: .infinity)
                        .background(AppTheme.selectedFill, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(appearance == option ? AppTheme.accent : AppTheme.border, lineWidth: appearance == option ? 2 : 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(EmberButtonStyle(appearance: .plain))
                    .accessibilityLabel(option.title)
                    .accessibilityValue(appearance == option ? "Selected" : "Not selected")
                    .accessibilityAddTraits(appearance == option ? .isSelected : [])
                }
            }
        }
    }
}

private struct AppearanceThumbnail: View {
    let appearance: AppAppearance

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = geometry.size.width * 0.32
            ZStack {
                miniature(sidebarWidth: sidebarWidth)
                    .environment(\.colorScheme, appearance == .dark ? .dark : .light)
                if appearance == .system {
                    miniature(sidebarWidth: sidebarWidth)
                        .environment(\.colorScheme, .dark)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: geometry.size.width / 2)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border, lineWidth: 1) }
        }
        .accessibilityHidden(true)
    }

    private func miniature(sidebarWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                EmberAppMark(size: 19)
                    .padding(.bottom, 5)
                sidebarRow("waveform", selected: true)
                sidebarRow("person.wave.2")
                sidebarRow("clock")
            }
            .padding(7)
            .frame(width: sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(AppTheme.sidebar)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Capsule().fill(AppTheme.primaryText).frame(width: 18, height: 4)
                    Spacer(minLength: 2)
                    Image(systemName: "mic")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(AppTheme.actionText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(AppTheme.actionFill, in: Capsule())
                }
                Capsule().fill(AppTheme.primaryText).frame(width: 34, height: 6)
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(AppTheme.primaryText).frame(width: 24, height: 4)
                    Capsule().fill(AppTheme.secondaryText).frame(height: 3)
                    Capsule().fill(AppTheme.secondaryText).frame(width: 18, height: 3)
                }
                .padding(8)
                .omdoGlassBackground(in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppTheme.background)
        }
    }

    private func sidebarRow(_ symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 7))
                .frame(width: 8)
            Capsule().frame(height: 3)
        }
        .foregroundStyle(AppTheme.primaryText)
        .padding(4)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5).fill(AppTheme.selectedFill)
            }
        }
    }
}
