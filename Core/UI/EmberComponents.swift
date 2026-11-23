import SwiftUI

struct EmberButtonStyle: ButtonStyle {
    enum Appearance {
        case standard, primary, inline, plain
        case icon(size: CGFloat, bordered: Bool, highlighted: Bool)
    }

    var appearance: Appearance
    @Environment(\.isEnabled) private var isEnabled

    init(primary: Bool = false) {
        appearance = primary ? .primary : .standard
    }

    init(appearance: Appearance) {
        self.appearance = appearance
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBody(configuration: configuration, isEnabled: isEnabled)
    }

    fileprivate func makeBody(configuration: Configuration, isEnabled: Bool) -> some View {
        face(for: configuration)
            // Apply after sizing and padding so gaps and clear areas click.
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }

    @ViewBuilder
    private func face(for configuration: Configuration) -> some View {
        switch appearance {
        case .standard, .primary:
            let isPrimary: Bool = if case .primary = appearance { true } else { false }
            configuration.label
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isPrimary ? AppTheme.actionText : AppTheme.primaryText)
                .background {
                    if isPrimary {
                        Capsule().fill(AppTheme.actionFill)
                    } else {
                        OmdoGlass(shape: Capsule())
                    }
                }
        case .inline:
            configuration.label.padding(.horizontal, 4).padding(.vertical, 3)
        case .plain:
            configuration.label
        case let .icon(size, bordered, highlighted):
            configuration.label
                .font(.system(size: 14))
                .frame(width: size, height: size)
                .background {
                    if highlighted {
                        Circle().fill(AppTheme.selectedFill)
                    } else if bordered {
                        OmdoGlass(shape: Circle())
                    } else if configuration.isPressed {
                        RoundedRectangle(cornerRadius: 7).fill(AppTheme.controlFill)
                    }
                }
        }
    }
}

struct EmberInlineActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        EmberButtonStyle(appearance: .inline).makeBody(configuration: configuration, isEnabled: isEnabled)
    }
}

struct EmberIconButtonStyle: ButtonStyle {
    var bordered = false
    var size: CGFloat = 29
    var highlighted = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        EmberButtonStyle(appearance: .icon(size: size, bordered: bordered, highlighted: highlighted))
            .makeBody(configuration: configuration, isEnabled: isEnabled)
    }
}

struct EmberReadyBadge: View {
    var title = "Ready"

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let label = Label(title, systemImage: "checkmark.circle.fill")
            .foregroundStyle(AppTheme.ready)

        if colorScheme == .dark {
            label
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppTheme.ready.opacity(0.14), in: Capsule())
        } else {
            label
        }
    }
}

struct EmberPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous)
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .omdoGlassBackground(in: shape)
            .clipShape(shape)
    }
}

struct EmberRow<Control: View>: View {
    let title: String
    var detail = ""
    var asset: String? = nil
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
        HStack(spacing: 10) {
            if let asset {
                EmberProviderIcon(asset: asset, size: 28)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        Image("OmdoMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(AppTheme.brandPrimary)
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .omdoGlassBackground(in: RoundedRectangle(cornerRadius: size * 0.26), tint: AppTheme.brandTile)
            .accessibilityHidden(true)
    }
}

/// Download progress bar that always transitions between the indeterminate
/// and determinate states. A single `ProgressView(value:)` created while the
/// value is nil keeps its indeterminate animation on macOS instead of
/// switching to the determinate bar once the total size is known, so the two
/// states must be distinct views.
struct EmberDownloadProgress: View {
    let value: Double?

    var body: some View {
        if let value {
            ProgressView(value: value).tint(AppTheme.accent)
        } else {
            ProgressView().progressViewStyle(.linear).tint(AppTheme.accent)
        }
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
    var onPrimary = false

    var body: some View {
        let ink = onPrimary ? AppTheme.actionText : AppTheme.primaryText
        let shape = RoundedRectangle(cornerRadius: 6)

        HStack(spacing: 5) {
            ForEach(shortcut.displayParts) { part in
                Group {
                    if let symbol = part.symbol { Image(systemName: symbol) }
                    else { Text(part.title) }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(ink.opacity(0.08), in: shape)
        .overlay { shape.strokeBorder(ink.opacity(0.15), lineWidth: 1) }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.displayValue)
    }
}

struct EmberWarningIcon: View {
    static let symbol = "exclamationmark.triangle.fill"

    var body: some View {
        Image(systemName: Self.symbol)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(AppTheme.warning)
            .accessibilityHidden(true)
    }
}

struct EmberWarningLabel: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Label { Text(message) } icon: { EmberWarningIcon() }
    }
}

struct EmberErrorBanner: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            EmberWarningIcon().font(.system(size: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(EmberInlineActionButtonStyle()).padding(.top, 3)
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
                    .buttonStyle(EmberIconButtonStyle()).accessibilityLabel("Dismiss notice")
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
            .buttonStyle(EmberButtonStyle(appearance: .plain))
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
