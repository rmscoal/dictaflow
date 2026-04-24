import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: DictaFlowAppState

    private let dashboardColumns = [
        GridItem(.flexible(minimum: 280), spacing: 14),
        GridItem(.flexible(minimum: 280), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection

                    LazyVGrid(columns: dashboardColumns, spacing: 14) {
                        recordingPanel
                        modelPanel
                    }

                    if hasMissingRequiredSettings {
                        settingsWarningPanel
                    }

                    LazyVGrid(columns: dashboardColumns, spacing: 14) {
                        systemStatusPanel
                        insertionPanel
                    }

                    if hasRecentActivity {
                        recentActivityPanel
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footerSection
        }
        .frame(minWidth: 860, minHeight: 660)
        .background(mainBackground)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: appState.menuBarIconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(appState.recordingState.isRecording ? .red : .cyan)

                    Text("DictaFlow")
                        .font(.system(size: 32, weight: .semibold))
                }

                Text("Local-first voice dictation for macOS")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(appState.menuBarStatusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text("GLOBAL KEYBIND")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(appState.hotkeyDisplayText)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(appState.isHotkeyRegistered ? Color.cyan.opacity(0.48) : Color.orange.opacity(0.58), lineWidth: 1)
                    )

                Text(appState.isHotkeyRegistered ? "Registered system-wide" : "Registration needs attention")
                    .font(.system(size: 12))
                    .foregroundStyle(appState.isHotkeyRegistered ? Color.secondary : Color.orange)
            }
        }
    }

    private var recordingPanel: some View {
        MainPanelSection(title: "Recording", systemImage: appState.dictationActionSymbolName) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(appState.dictationActionTitle)
                        .font(.system(size: 22, weight: .semibold))

                    Spacer()

                    stateBadge(appState.recordingState.isRecording ? "LIVE" : "READY", color: appState.recordingState.isRecording ? .red : .cyan)
                }

                Text(appState.dictationSummaryText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(appState.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        appState.toggleDictation()
                    } label: {
                        Label(appState.dictationActionTitle, systemImage: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(appState.recordingState.isRecording ? .red : .cyan)
                    .disabled(appState.transcriptionState.isTranscribing || appState.textInsertionState.isBusy)

                    Button {
                        appState.openSettingsWindow()
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }

    private var modelPanel: some View {
        MainPanelSection(title: "Model", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.whisperConfiguration.model.displayName)
                            .font(.system(size: 22, weight: .semibold))

                        Text(appState.whisperConfigurationSummaryText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    stateBadge(appState.whisperConfiguration.model.approximateDiskSizeDescription, color: .cyan)
                }

                Text(appState.modelStatusText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(appState.whisperConfiguration.model.detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        appState.openModelsFolder()
                    } label: {
                        Label("Open Model Folder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)

                    Button {
                        appState.retryModelPreparation()
                    } label: {
                        Label("Prepare", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var settingsWarningPanel: some View {
        MainPanelSection(title: "Settings Warning", systemImage: "exclamationmark.triangle.fill", isWarning: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Required access is missing")
                        .font(.system(size: 18, weight: .semibold))

                    Spacer()

                    stateBadge("ACTION", color: .orange)
                }

                LazyVGrid(columns: dashboardColumns, spacing: 12) {
                    if appState.microphonePermissionState != .granted {
                        MissingAccessTile(
                            title: "Microphone",
                            state: appState.microphonePermissionState.title,
                            detail: appState.microphonePermissionState.detailText,
                            systemImage: "mic.slash"
                        )
                    }

                    if appState.accessibilityPermissionState != .granted {
                        MissingAccessTile(
                            title: "Accessibility",
                            state: appState.accessibilityPermissionState.title,
                            detail: appState.accessibilityPermissionState.detailText,
                            systemImage: "figure.wave.circle"
                        )
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        appState.refreshMicrophonePermissionStatus()
                        appState.refreshAccessibilityPermissionStatus()
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    if appState.accessibilityPermissionState != .granted {
                        Button {
                            appState.openAccessibilitySettings()
                        } label: {
                            Label("Open Accessibility", systemImage: "gear")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
            }
        }
    }

    private var systemStatusPanel: some View {
        MainPanelSection(title: "System", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 12) {
                StatusLine(
                    title: "Microphone",
                    value: appState.microphonePermissionState.title,
                    systemImage: "mic.fill",
                    color: appState.microphonePermissionState == .granted ? .cyan : .orange
                )

                StatusLine(
                    title: "Accessibility",
                    value: appState.accessibilityPermissionState.title,
                    systemImage: "figure.wave.circle",
                    color: appState.accessibilityPermissionState == .granted ? .cyan : .orange
                )

                StatusLine(
                    title: "Launch",
                    value: appState.launchBehaviorText,
                    systemImage: "arrow.up.forward.app",
                    color: .secondary
                )
            }
        }
    }

    private var insertionPanel: some View {
        MainPanelSection(title: "Transcript", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: 12) {
                Label(appState.textInsertionStatusText, systemImage: "text.cursor")
                    .font(.system(size: 14, weight: .semibold))

                if let lastTextInsertion = appState.lastTextInsertion {
                    Text(lastTextInsertion.method.title)
                        .font(.system(size: 13, weight: .semibold))

                    Text(lastTextInsertion.method.detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("After transcription finishes, DictaFlow targets the focused app and falls back through Accessibility, paste, simulated typing, then copy panel.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        appState.insertLastTranscription()
                    } label: {
                        Label("Insert Again", systemImage: "arrow.uturn.forward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appState.canInsertLastTranscription)

                    Button {
                        appState.copyLastTranscription()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appState.canCopyLastTranscription)
                }
            }
        }
    }

    private var recentActivityPanel: some View {
        MainPanelSection(title: "Recent Activity", systemImage: "waveform.path") {
            VStack(alignment: .leading, spacing: 14) {
                if let lastTranscription = appState.lastTranscription {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "\(lastTranscription.taskMode.title) / \(lastTranscription.detectedLanguageDisplayName)",
                            systemImage: "text.bubble.fill"
                        )
                        .font(.system(size: 14, weight: .semibold))

                        Text(lastTranscription.text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Completed at \(lastTranscription.completedAt.formatted(date: .abbreviated, time: .standard)) using \(lastTranscription.model.displayName).")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastCapture = appState.lastCapture {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Capture / \(lastCapture.durationText)", systemImage: "waveform")
                            .font(.system(size: 14, weight: .semibold))

                        Text(lastCapture.fileURL.path)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Button {
                appState.closeMainWindow()
            } label: {
                Label("Hide Window", systemImage: "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)

            Spacer()

            Text(appState.launchBehaviorText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var mainBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.cyan.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            MainWindowGridOverlay()
                .stroke(Color.cyan.opacity(0.06), lineWidth: 0.6)
        }
    }

    private var hasMissingRequiredSettings: Bool {
        appState.microphonePermissionState != .granted || appState.accessibilityPermissionState != .granted
    }

    private var hasRecentActivity: Bool {
        appState.lastTranscription != nil || appState.lastCapture != nil
    }

    private func stateBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct MainPanelSection<Content: View>: View {
    let title: String
    let systemImage: String
    var isWarning = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isWarning ? .orange : .secondary)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isWarning ? Color.orange.opacity(0.38) : Color.cyan.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct MissingAccessTile: View {
    let title: String
    let state: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Text(state)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatusLine: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

private struct MainWindowGridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 24

        var x = rect.minX
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }

        var y = rect.minY
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }

        return path
    }
}
