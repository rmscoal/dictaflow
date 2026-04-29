import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            shortcutSection
            recordingCard
            modelsCard
            footerActions
        }
        .padding(9)
        .frame(width: 318, alignment: .leading)
        .foregroundStyle(MenuTheme.primaryText)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MenuTheme.panelFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(MenuTheme.panelBorder, lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 14)
                .shadow(color: .white.opacity(0.03), radius: 18, x: 0, y: 0)
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle("Global Shortcut")

            HStack(spacing: 6) {
                ShortcutKeycap(symbol: "command", title: "Command")
                ShortcutPlus()
                ShortcutKeycap(symbol: "shift", title: "Shift")
                ShortcutPlus()
                ShortcutKeycap(title: "\\", minWidth: 28)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var recordingCard: some View {
        MenuCard {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(MenuTheme.controlFill)
                            .overlay(Circle().stroke(MenuTheme.border, lineWidth: 0.75))

                        Image(systemName: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MenuTheme.primaryText)
                    }
                    .frame(width: 30, height: 30)
                    .overlay(alignment: .topTrailing) {
                        if appState.recordingState.isRecording {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 6, height: 6)
                                .shadow(color: .white.opacity(0.55), radius: 5)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.recordingState.isRecording ? "Recording" : "Ready")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MenuTheme.primaryText)

                        Text(recordingSubtitle)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(MenuTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    WaveformMark()
                        .frame(width: 28, height: 18)
                        .foregroundStyle(MenuTheme.tertiaryText)
                }

                Button {
                    appState.toggleDictation()
                } label: {
                    Label(appState.dictationActionTitle, systemImage: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(PrimaryRecordButtonStyle(isRecording: appState.recordingState.isRecording))
                .disabled(appState.transcriptionState.isBusy || appState.textInsertionState.isBusy)
            }
        }
    }

    private var modelsCard: some View {
        MenuCard {
            VStack(alignment: .leading, spacing: 7) {
                SectionTitle("Models")

                ModelRow(
                    icon: "waveform",
                    title: "Speech-to-Text (Whisper.cpp)",
                    subtitle: appState.whisperConfiguration.model.displayName,
                    trailing: {
                        Menu {
                            ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                                Button(model.displayName) {
                                    appState.prepareAndUseModel(model)
                                }
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
                    title: "Refine with LLM",
                    subtitle: appState.refinementModelMenuTitle(for: appState.refinementConfiguration.model),
                    trailing: {
                        HStack(spacing: 6) {
                            Toggle("", isOn: refinementEnabledBinding)
                                .labelsHidden()
                                .toggleStyle(MonochromeSwitchStyle())
                                .disabled(appState.whisperSettingsLocked)

                            Menu {
                                ForEach(RefinementModelDescriptor.allCases, id: \.self) { model in
                                    Button(appState.refinementModelMenuTitle(for: model)) {
                                        appState.updateRefinementModel(model)
                                    }
                                    .disabled(!appState.isRefinementModelSupported(model))
                                }
                            } label: {
                                ChevronButtonLabel()
                            }
                            .buttonStyle(.plain)
                            .disabled(appState.whisperSettingsLocked)
                        }
                    }
                )

                Text("When enabled, transcriptions are refined using the selected LLM.")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(MenuTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: 7) {
            Button {
                appState.showMainWindow()
            } label: {
                Label("Open Main App", systemImage: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(GhostButtonStyle(radius: 10))

            Spacer(minLength: 10)

            Button {
                appState.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(GhostButtonStyle(radius: 10))
            .help("Settings")

            Rectangle()
                .fill(MenuTheme.divider)
                .frame(width: 0.75, height: 22)

            Button {
                appState.quit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(GhostButtonStyle(radius: 10))
            .help("Quit")
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    private var refinementEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.refinementConfiguration.isEnabled },
            set: { appState.updateRefinementEnabled($0) }
        )
    }

    private var recordingSubtitle: String {
        if appState.recordingState.isRecording {
            return "Tap again to finish and transcribe"
        }

        if appState.transcriptionState.isBusy || appState.textInsertionState.isBusy {
            return appState.menuBarStatusText
        }

        return "Start recording to transcribe"
    }
}

struct MenuBarIconView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        Image(systemName: appState.menuBarIconName)
            .accessibilityLabel("DictaFlow")
    }
}

private struct MenuCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MenuTheme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(MenuTheme.cardBorder, lineWidth: 0.75)
            )
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(MenuTheme.titleText)
    }
}

private struct ShortcutKeycap: View {
    var symbol: String?
    let title: String
    var minWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
            }

            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(MenuTheme.primaryText)
        .padding(.horizontal, 7)
        .frame(minWidth: minWidth, minHeight: 24)
        .background(MenuTheme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MenuTheme.border, lineWidth: 0.75)
        )
    }
}

private struct ShortcutPlus: View {
    var body: some View {
        Text("+")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(MenuTheme.primaryText)
            .frame(width: 9)
    }
}

private struct ModelRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            IconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MenuTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(MenuTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            trailing
        }
    }
}

private struct IconTile: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MenuTheme.primaryText)
            .frame(width: 26, height: 26)
            .background(MenuTheme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MenuTheme.border, lineWidth: 0.75)
            )
    }
}

private struct ChevronButtonLabel: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MenuTheme.primaryText)
            .frame(width: 26, height: 24)
            .background(MenuTheme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MenuTheme.border, lineWidth: 0.75)
            )
    }
}

private struct WaveformMark: View {
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach([4, 9, 14, 9, 5], id: \.self) { height in
                Capsule(style: .continuous)
                    .frame(width: 2.5, height: CGFloat(height))
            }
        }
    }
}

private struct PrimaryRecordButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isRecording ? MenuTheme.primaryText : Color.black.opacity(0.95))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isRecording ? Color.black.opacity(0.62) : Color.white.opacity(configuration.isPressed ? 0.86 : 0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isRecording ? Color.white.opacity(0.45) : Color.white.opacity(0.12), lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeInOut(duration: 0.18), value: configuration.isPressed)
    }
}

private struct GhostButtonStyle: ButtonStyle {
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(MenuTheme.primaryText)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.085) : MenuTheme.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(MenuTheme.border, lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeInOut(duration: 0.18), value: configuration.isPressed)
    }
}

private struct MonochromeSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                configuration.isOn.toggle()
            }
        } label: {
            Capsule(style: .continuous)
                .fill(configuration.isOn ? Color.white.opacity(0.18) : Color.white.opacity(0.10))
                .frame(width: 30, height: 16)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.white : Color.white.opacity(0.42))
                        .frame(width: 12, height: 12)
                        .padding(2)
                }
                .overlay(Capsule(style: .continuous).stroke(MenuTheme.border, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }
}

private enum MenuTheme {
    static let panelFill = Color(red: 0.039, green: 0.039, blue: 0.039).opacity(0.92)
    static let panelBorder = Color.white.opacity(0.08)
    static let cardFill = Color.white.opacity(0.025)
    static let cardBorder = Color.white.opacity(0.06)
    static let controlFill = Color.white.opacity(0.05)
    static let border = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.05)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.45)
    static let tertiaryText = Color.white.opacity(0.32)
    static let titleText = Color.white.opacity(0.55)
}
