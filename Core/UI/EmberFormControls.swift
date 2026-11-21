import SwiftUI

struct EmberSwitchStyle: ToggleStyle {
    var showsLabel = true
    var contentInsets = EdgeInsets()

    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        if colorScheme == .dark {
            EmberSwitchButton(configuration: configuration, showsLabel: showsLabel, contentInsets: contentInsets)
        } else {
            Toggle(configuration).toggleStyle(.switch).padding(contentInsets)
        }
    }
}

private struct EmberSwitchButton: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool
    let contentInsets: EdgeInsets

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                if showsLabel {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                }
                track
                    .frame(minWidth: 44, minHeight: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.accent, lineWidth: 1.5)
                            .opacity(isFocused && isEnabled ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .accessibilityHidden(true)
            }
            .padding(contentInsets)
        }
        .buttonStyle(EmberButtonStyle(appearance: .plain))
        .focused($isFocused)
        .accessibilityRepresentation {
            Toggle(configuration).toggleStyle(.switch)
        }
    }

    private var track: some View {
        let compact = controlSize == .mini
        let height: CGFloat = compact ? 18 : 20
        let isOn = configuration.isOn
        let shape = Capsule()

        return shape
            .fill(isOn ? AppTheme.actionFill : AppTheme.opaqueControlFill)
            .overlay { shape.strokeBorder(isOn ? .clear : AppTheme.border, lineWidth: 1) }
            .frame(width: compact ? 32 : 38, height: height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? AppTheme.actionText : AppTheme.primaryText)
                    .frame(width: height - 6, height: height - 6)
                    .padding(.horizontal, 3)
            }
    }
}

/// Uses the same contrast for the value and chevrons in the closed menu.
struct EmberSelectionMenu<Items: View>: View {
    let label: String
    let title: String
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu(content: items) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 200)
            .omdoControlBackground(in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(EmberButtonStyle(appearance: .plain))
        .menuIndicator(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }
}
