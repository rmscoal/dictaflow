import SwiftUI

struct AppearanceSettingsView: View {
    @Binding var appearance: AppAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THEME")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.secondaryText)

            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("App appearance")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Use your Mac’s appearance or choose your own.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                HStack(spacing: 14) {
                    ForEach(AppAppearance.allCases) { option in
                        Button {
                            appearance = option
                        } label: {
                            VStack(spacing: 9) {
                                AppearanceThumbnail(appearance: option)
                                    .frame(height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(appearance == option ? AppTheme.accent : AppTheme.border, lineWidth: appearance == option ? 2 : 1)
                                    }

                                HStack(spacing: 5) {
                                    Image(systemName: appearance == option ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(appearance == option ? AppTheme.accent : AppTheme.secondaryText)
                                    Text(option.title)
                                }
                                .font(.system(size: 12))
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityValue(appearance == option ? "Selected" : "Not selected")
                        .accessibilityAddTraits(appearance == option ? .isSelected : [])
                    }
                }

                Divider().overlay(AppTheme.border)

                Text(appearance.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(AppTheme.border, lineWidth: 0.75)
            }

            Text("Applies to the main window, menu bar popover, and recording pill.")
                .font(.system(size: 10.5))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AppTheme.primaryText)
    }
}

/// These previews intentionally show fixed themes, independent of the selection.
private struct AppearanceThumbnail: View {
    let appearance: AppAppearance

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                miniature(isDark: appearance == .dark)
                if appearance == .system {
                    miniature(isDark: true)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: geometry.size.width / 2)
                        }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func miniature(isDark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 5) {
                Capsule().fill(Color.white.opacity(0.8)).frame(width: 12, height: 3)
                RoundedRectangle(cornerRadius: 2).fill(AppTheme.accent).frame(height: 7)
                Capsule().fill(isDark ? Color.gray : Color.gray.opacity(0.5)).frame(height: 3)
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(width: 29)
            .background(isDark ? Color(red: 0.125, green: 0.165, blue: 0.220) : Color(red: 0.925, green: 0.937, blue: 0.953))

            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(isDark ? Color.white.opacity(0.8) : Color.black.opacity(0.7))
                    .frame(width: 28, height: 4)
                RoundedRectangle(cornerRadius: 3)
                    .fill(isDark ? Color.white.opacity(0.08) : Color.white)
                    .frame(height: 21)
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity)
            .background(isDark ? Color(red: 0.09, green: 0.098, blue: 0.114) : Color(red: 0.969, green: 0.969, blue: 0.973))
        }
        .padding(6)
        .background(isDark ? Color(red: 0.23, green: 0.25, blue: 0.37) : Color(red: 0.78, green: 0.81, blue: 0.94))
    }
}
