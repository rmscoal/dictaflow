import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 8) {
                recordingCard
                modelsCard
            }
            .padding(10)

            footerActions
        }
        .frame(width: MenuLayout.width)
        .foregroundStyle(MenuTheme.primaryText)
        .background(MenuTheme.background)
    }

    private var header: some View {
        HStack(spacing: 9) {
            DictaFlowMenuMark()

            Text("DictaFlow")
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.15)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: MenuLayout.headerHeight)
        .background(MenuTheme.headerFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MenuTheme.strongDivider)
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DictaFlow")
    }

    private var recordingCard: some View {
        HStack(spacing: 13) {
            Button {
                appState.toggleDictation()
            } label: {
                Image(systemName: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: appState.recordingState.isRecording ? 16 : 20, weight: .medium))
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(RecordControlButtonStyle(isRecording: appState.recordingState.isRecording))
            .disabled(isRecordControlDisabled)
            .help(appState.dictationActionTitle)

            VStack(alignment: .leading, spacing: 6) {
                Text(appState.recordingState.isRecording ? "Listening…" : "Ready to dictate")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MenuTheme.primaryText)

                recordingDetail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: MenuLayout.recordingCardHeight, alignment: .leading)
        .background(
            LinearGradient(
                colors: [MenuTheme.recordingCardTop, MenuTheme.recordingCardBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MenuTheme.cardBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var recordingDetail: some View {
        if appState.transcriptionState.isBusy || appState.textInsertionState.isBusy {
            Text(appState.menuBarStatusText)
                .font(.system(size: 9.5))
                .foregroundStyle(MenuTheme.secondaryText)
                .lineLimit(1)
        } else {
            HStack(spacing: 4) {
                Text(appState.recordingState.isRecording ? "Click stop or press" : "Click the microphone or press")
                    .font(.system(size: 9.5))
                    .foregroundStyle(MenuTheme.secondaryText)
                    .lineLimit(1)

                CompactShortcutKeycap(shortcut: appState.globalShortcut)
            }
        }
    }

    private var modelsCard: some View {
        VStack(spacing: 0) {
            ModelRow(
                icon: "waveform",
                title: "Whisper model",
                subtitle: "\(appState.whisperConfiguration.model.displayName) · Multilingual",
                trailing: {
                    Menu {
                        ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                            Button {
                                appState.updateWhisperModel(model)
                            } label: {
                                if model == appState.whisperConfiguration.model {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                            .disabled(!appState.isWhisperModelPrepared(model))
                        }
                    } label: {
                        ChevronButtonLabel()
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.whisperSettingsLocked)
                }
            )

            Divider()
                .overlay(MenuTheme.divider)

            ModelRow(
                icon: "sparkles",
                title: "Text refinement",
                subtitle: refinementSubtitle,
                trailing: {
                    HStack(spacing: 6) {
                        Toggle("", isOn: refinementEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(AccentSwitchStyle())
                            .disabled(appState.whisperSettingsLocked)

                        Menu {
                            ForEach(RefinementModelDescriptor.allCases, id: \.self) { model in
                                Button {
                                    appState.updateRefinementModel(model)
                                } label: {
                                    if model == appState.refinementConfiguration.model {
                                        Label(appState.refinementModelMenuTitle(for: model), systemImage: "checkmark")
                                    } else {
                                        Text(appState.refinementModelMenuTitle(for: model))
                                    }
                                }
                                .disabled(
                                    !appState.isRefinementModelSupported(model)
                                        || !appState.isRefinementModelPrepared(model)
                                )
                            }
                        } label: {
                            ChevronButtonLabel()
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.whisperSettingsLocked)
                    }
                }
            )
        }
        .background(MenuTheme.modelsFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(MenuTheme.modelsBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var footerActions: some View {
        HStack(spacing: 6) {
            Button {
                dismiss()
                appState.openSettingsWindow()
            } label: {
                HStack(spacing: 7) {
                    Text("Open Settings")
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(MenuTheme.tertiaryText)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(GhostButtonStyle(emphasized: true))

            if let availableUpdate = appState.availableUpdate {
                Button {
                    appState.openAvailableUpdate()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(GhostButtonStyle())
                .help("Version \(availableUpdate.version.displayString) is available")
            }

            Button {
                appState.quit()
            } label: {
                Text("Quit")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 30)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Quit DictaFlow")
        }
        .padding(.horizontal, 10)
        .frame(height: MenuLayout.footerHeight)
        .background(MenuTheme.footerFill)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MenuTheme.strongDivider)
                .frame(height: 1)
        }
    }

    private var isRecordControlDisabled: Bool {
        appState.isEditingGlobalShortcut
            || appState.transcriptionState.isBusy
            || appState.textInsertionState.isBusy
    }

    private var refinementEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.refinementConfiguration.isEnabled },
            set: { appState.updateRefinementEnabled($0) }
        )
    }

    private var refinementSubtitle: String {
        guard appState.refinementConfiguration.isEnabled else {
            return "Off · Raw Whisper output"
        }

        return "\(appState.refinementModelMenuTitle(for: appState.refinementConfiguration.model)) · Local"
    }
}

struct MenuBarIconView: View {
    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .accessibilityLabel("DictaFlow")
    }

    private static let templateImage: NSImage = {
        let imageSize = NSSize(width: 18, height: 18)
        let barWidth: CGFloat = 2
        let barSpacing: CGFloat = 1.5
        let barHeights: [CGFloat] = [6, 10, 15, 10, 6]
        let markWidth = CGFloat(barHeights.count) * barWidth
            + CGFloat(barHeights.count - 1) * barSpacing
        let leadingInset = (imageSize.width - markWidth) / 2

        let image = NSImage(size: imageSize, flipped: false) { _ in
            NSColor.black.setFill()

            for (index, height) in barHeights.enumerated() {
                let x = leadingInset + CGFloat(index) * (barWidth + barSpacing)
                let y = (imageSize.height - height) / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                NSBezierPath(
                    roundedRect: barRect,
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                ).fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }()
}

private struct DictaFlowMenuMark: View {
    var body: some View {
        DictaFlowWaveformMark(
            barWidth: 2.3,
            spacing: 2,
            barHeights: [8, 14, 20, 14, 8]
        )
        .foregroundStyle(MenuTheme.logoBar)
        .frame(width: 29, height: 29)
        .background(Color.white, in: Circle())
        .shadow(color: .black.opacity(0.18), radius: 6.5, x: 0, y: 2.5)
        .accessibilityHidden(true)
    }
}

private struct DictaFlowWaveformMark: View {
    let barWidth: CGFloat
    let spacing: CGFloat
    let barHeights: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                Capsule(style: .continuous)
                    .fill(.foreground)
                    .frame(width: barWidth, height: height)
            }
        }
    }
}

private struct CompactShortcutKeycap: View {
    let shortcut: GlobalShortcutDescriptor

    var body: some View {
        Text(compactText)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(MenuTheme.keycapText)
            .padding(.horizontal, 5)
            .frame(minHeight: 17)
            .background(MenuTheme.controlFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(MenuTheme.controlBorder, lineWidth: 1)
            }
            .accessibilityLabel(shortcut.displayValue)
    }

    private var compactText: String {
        shortcut.displayParts.map { part in
            switch part.symbol {
            case "command":
                return "⌘"
            case "option":
                return "⌥"
            case "control":
                return "⌃"
            case "shift":
                return "⇧"
            default:
                return part.title
            }
        }
        .joined(separator: " ")
    }
}

private struct ModelRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MenuTheme.accentTint)
                .frame(width: 25, height: 25)
                .background(MenuTheme.accentFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(MenuTheme.accentBorder, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MenuTheme.primaryText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(MenuTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(minHeight: MenuLayout.modelRowHeight)
    }
}

private struct ChevronButtonLabel: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MenuTheme.chevronText)
            .frame(width: 25, height: 24)
            .background(MenuTheme.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(MenuTheme.controlBorder, lineWidth: 1)
            }
    }
}

private struct RecordControlButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .background(
                isRecording ? MenuTheme.recording : MenuTheme.accent,
                in: Circle()
            )
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.17), lineWidth: 1)
            }
            .shadow(
                color: (isRecording ? MenuTheme.recording : MenuTheme.accent).opacity(0.38),
                radius: 11,
                x: 0,
                y: 5
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct GhostButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration, emphasized: emphasized)
    }

    private struct GhostButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let emphasized: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(foregroundColor)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHovering)
                .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
        }

        private var foregroundColor: Color {
            if isHovering || configuration.isPressed {
                return MenuTheme.primaryText
            }

            return emphasized ? MenuTheme.footerPrimaryText : MenuTheme.footerText
        }

        private var backgroundColor: Color {
            if configuration.isPressed {
                return Color.white.opacity(0.085)
            }

            return isHovering ? Color.white.opacity(0.055) : Color.clear
        }

        private var borderColor: Color {
            isHovering || configuration.isPressed ? Color.white.opacity(0.065) : Color.clear
        }
    }
}

private struct AccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                configuration.isOn.toggle()
            }
        } label: {
            Capsule(style: .continuous)
                .fill(configuration.isOn ? MenuTheme.accent : MenuTheme.switchOffFill)
                .frame(width: 31, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.white : MenuTheme.switchOffThumb)
                        .frame(width: 11, height: 11)
                        .padding(2)
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private enum MenuLayout {
    static let width: CGFloat = 318
    static let headerHeight: CGFloat = 56
    static let recordingCardHeight: CGFloat = 86
    static let modelRowHeight: CGFloat = 51
    static let footerHeight: CGFloat = 47
}

private enum MenuTheme {
    static let background = Color(red: 23 / 255, green: 25 / 255, blue: 29 / 255)
    static let headerFill = Color(red: 32 / 255, green: 42 / 255, blue: 56 / 255)
    static let footerFill = Color(red: 27 / 255, green: 29 / 255, blue: 33 / 255)
    static let recordingCardTop = Color(red: 35 / 255, green: 37 / 255, blue: 42 / 255)
    static let recordingCardBottom = Color(red: 31 / 255, green: 33 / 255, blue: 37 / 255)
    static let modelsFill = Color(red: 28 / 255, green: 30 / 255, blue: 34 / 255)
    static let accent = Color(red: 77 / 255, green: 120 / 255, blue: 251 / 255)
    static let recording = Color(red: 224 / 255, green: 82 / 255, blue: 95 / 255)
    static let cardBorder = Color(red: 48 / 255, green: 50 / 255, blue: 56 / 255)
    static let modelsBorder = Color(red: 45 / 255, green: 48 / 255, blue: 53 / 255)
    static let controlFill = Color(red: 41 / 255, green: 43 / 255, blue: 48 / 255)
    static let controlBorder = Color(red: 58 / 255, green: 61 / 255, blue: 67 / 255)
    static let divider = Color(red: 42 / 255, green: 45 / 255, blue: 50 / 255)
    static let strongDivider = Color(red: 9 / 255, green: 10 / 255, blue: 12 / 255)
    static let primaryText = Color(red: 244 / 255, green: 245 / 255, blue: 247 / 255)
    static let secondaryText = Color(red: 133 / 255, green: 139 / 255, blue: 148 / 255)
    static let tertiaryText = Color(red: 133 / 255, green: 139 / 255, blue: 148 / 255)
    static let keycapText = Color(red: 185 / 255, green: 190 / 255, blue: 198 / 255)
    static let chevronText = Color(red: 189 / 255, green: 194 / 255, blue: 201 / 255)
    static let footerPrimaryText = Color(red: 205 / 255, green: 209 / 255, blue: 215 / 255)
    static let footerText = Color(red: 174 / 255, green: 179 / 255, blue: 187 / 255)
    static let accentTint = Color(red: 118 / 255, green: 153 / 255, blue: 255 / 255)
    static let accentFill = Color(red: 82 / 255, green: 127 / 255, blue: 255 / 255).opacity(0.10)
    static let accentBorder = Color(red: 108 / 255, green: 146 / 255, blue: 255 / 255).opacity(0.13)
    static let logoBar = Color(red: 16 / 255, green: 19 / 255, blue: 25 / 255)
    static let switchOffFill = Color(red: 58 / 255, green: 61 / 255, blue: 67 / 255)
    static let switchOffThumb = Color(red: 169 / 255, green: 173 / 255, blue: 180 / 255)
}
