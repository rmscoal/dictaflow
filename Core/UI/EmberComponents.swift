import SwiftUI

/// Keep material in navigation and transient surfaces, with a stable opaque fallback.
struct EmberMaterialFill: View {
    let tint: Color
    var tintOpacity = 0.97
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            tint
        } else {
            Rectangle().fill(.ultraThinMaterial).overlay(tint.opacity(tintOpacity))
        }
    }
}

struct EmberButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(primary ? AppTheme.actionText : AppTheme.primaryText)
            .background(primary ? AppTheme.actionFill : AppTheme.tileFill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(primary ? AppTheme.actionFill : AppTheme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct EmberIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .frame(width: 29, height: 29)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(configuration.isPressed ? AppTheme.controlFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

struct EmberPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.border, lineWidth: 1)
            }
    }
}

struct EmberRow<Control: View>: View {
    let title: String
    var detail = ""
    @ViewBuilder var control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                label
                Spacer(minLength: 12)
                control.fixedSize()
            }
            VStack(alignment: .leading, spacing: 14) {
                label
                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct EmberDivider: View {
    var body: some View { Rectangle().fill(AppTheme.border).frame(height: 1).accessibilityHidden(true) }
}

struct EmberPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, AppLayout.contentPadding)
                .padding(.top, 10)
                .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct EmberPageHeading: View {
    let title: String

    var body: some View {
        Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.8)
            .padding(.bottom, 24)
    }
}

struct EmberSectionHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 9)
    }
}

struct EmberModuleHeading: View {
    let title: String

    var body: some View {
        Text(title).font(.system(size: 21, weight: .medium)).tracking(-0.5)
            .padding(.bottom, 20)
    }
}

struct EmberAppMark: View {
    var size: CGFloat = 35

    var body: some View {
        HStack(spacing: size * 0.057) {
            ForEach(Array([0.24, 0.4, 0.57, 0.4, 0.24].enumerated()), id: \.offset) { _, height in
                Capsule().fill(Color.black).frame(width: size * 0.071, height: size * height)
            }
        }
        .frame(width: size, height: size)
        .background(.white, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct EmberProviderIcon: View {
    let asset: String
    var size: CGFloat = 32

    var body: some View {
        Image(asset).resizable().scaledToFit().padding(size * 0.15)
            .frame(width: size, height: size)
            .background(.white, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ShortcutKeycaps: View {
    let shortcut: GlobalShortcutDescriptor

    var body: some View {
        HStack(spacing: 4) {
            ForEach(shortcut.displayParts) { part in
                Group {
                    if let symbol = part.symbol { Image(systemName: symbol) }
                    else { Text(part.title) }
                }
                .font(.system(size: 12))
                .frame(minWidth: 21, minHeight: 22)
                .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).stroke(AppTheme.border, lineWidth: 1) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.displayValue)
    }
}

struct EmberErrorBanner: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.plain).padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(AppTheme.errorText)
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.errorFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(AppTheme.errorBorder, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

struct EmberInformationBanner: View {
    let title: String
    let message: String
    let dismiss: () -> Void

    var body: some View {
        EmberPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle").foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(message).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 0)
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
            }
            .padding(15)
        }
    }
}

/// Two flexible tracks that stack by available content width, without a page width cap.
struct EmberColumns: Layout {
    var ratio: CGFloat = 1.25
    var gap: CGFloat = 24
    var stackingWidth: CGFloat = AppLayout.workspaceStackingWidth

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? stackingWidth
        let sizes = sizes(width: width, subviews: subviews)
        let height = width > stackingWidth
            ? sizes.map(\.height).max() ?? 0
            : sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(width: bounds.width, subviews: subviews)
        var point = bounds.origin
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            subview.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(size))
            if bounds.width > stackingWidth { point.x += size.width + gap }
            else { point.y += size.height + gap }
        }
    }

    private func sizes(width: CGFloat, subviews: Subviews) -> [CGSize] {
        subviews.enumerated().map { index, subview in
            let columnWidth = width > stackingWidth ? max(0, width - gap) * (index == 0 ? ratio : 1) / (ratio + 1) : width
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            return CGSize(width: columnWidth, height: size.height)
        }
    }
}

/// Makes the complete disclosure header a keyboard-accessible toggle.
struct EmberDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
