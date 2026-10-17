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
                        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(appearance == option ? AppTheme.accent : AppTheme.border, lineWidth: appearance == option ? 2 : 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
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
            ZStack {
                miniature(dark: appearance == .dark)
                if appearance == .system {
                    miniature(dark: true).mask(alignment: .trailing) {
                        Rectangle().frame(width: geometry.size.width / 2)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border, lineWidth: 1) }
        }
        .accessibilityHidden(true)
    }

    private func miniature(dark: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill((dark ? Color(red: 38.0/255, green: 39.0/255, blue: 34.0/255) : Color(red: 233.0/255, green: 228.0/255, blue: 216.0/255)))
                .frame(width: 72)
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 10).fill(Color(red: dark ? 0.251 : 1, green: dark ? 0.224 : 0.992, blue: dark ? 0.176 : 0.973))
                    .frame(height: 68).padding(.horizontal, 16)
                Spacer()
            }
            .background(dark ? Color(red: 0.09, green: 0.094, blue: 0.086) : Color(red: 0.953, green: 0.941, blue: 0.914))
        }
    }
}
