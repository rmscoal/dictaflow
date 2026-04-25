import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            MenuPanelSection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Label(appState.dictationActionTitle, systemImage: appState.dictationActionSymbolName)
                            .font(.headline)

                        Spacer()

                        recordingStateBadge
                    }

                    Text(appState.dictationSummaryText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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
                }
            }

            MenuPanelSection(title: "Model", systemImage: "cpu") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appState.whisperConfiguration.model.displayName)
                                .font(.system(size: 15, weight: .semibold))

                            Text(appState.whisperConfigurationSummaryText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(appState.whisperConfiguration.model.approximateDiskSizeDescription)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }

                    Text(appState.modelStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button {
                            appState.openModelsFolder()
                        } label: {
                            Label("Open Model Folder", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            appState.retryModelPreparation()
                        } label: {
                            Label("Prepare", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if hasMissingRequiredSettings {
                MenuPanelSection(title: "Settings Warning", systemImage: "exclamationmark.triangle.fill", isWarning: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        if appState.microphonePermissionState != .granted {
                            MissingSettingRow(
                                title: "Microphone",
                                detail: appState.microphonePermissionState.detailText,
                                systemImage: "mic.slash"
                            )
                        }

                        if appState.accessibilityPermissionState != .granted {
                            MissingSettingRow(
                                title: "Accessibility",
                                detail: appState.accessibilityPermissionState.detailText,
                                systemImage: "figure.wave.circle"
                            )
                        }

                        HStack(spacing: 8) {
                            Button("Refresh") {
                                appState.refreshMicrophonePermissionStatus()
                                appState.refreshAccessibilityPermissionStatus()
                            }
                            .buttonStyle(.bordered)

                            if appState.accessibilityPermissionState != .granted {
                                Button("Open Accessibility") {
                                    appState.openAccessibilitySettings()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }

            MenuPanelSection(title: "Transcript", systemImage: "text.bubble") {
                VStack(alignment: .leading, spacing: 10) {
                    lastTranscriptPreview

                    HStack(spacing: 8) {
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

            Divider()

            HStack {
                Button(appState.isMainWindowVisible ? "Hide Main Window" : "Open Main Window") {
                    appState.toggleMainWindow()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Quit") {
                    appState.quit()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color.cyan.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                GridOverlay()
                    .stroke(Color.cyan.opacity(0.07), lineWidth: 0.6)
            }
        )
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: appState.menuBarIconName)
                        .foregroundStyle(appState.recordingState.isRecording ? .red : .cyan)

                    Text("DictaFlow")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text(appState.menuBarStatusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("GLOBAL")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(appState.hotkeyDisplayText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(appState.isHotkeyRegistered ? Color.cyan.opacity(0.45) : Color.orange.opacity(0.55), lineWidth: 1)
                    )
            }
        }
    }

    private var recordingStateBadge: some View {
        Text(appState.recordingState.isRecording ? "LIVE" : "READY")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(appState.recordingState.isRecording ? .red : .cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
    }

    private var hasMissingRequiredSettings: Bool {
        appState.microphonePermissionState != .granted || appState.accessibilityPermissionState != .granted
    }

    @ViewBuilder
    private var lastTranscriptPreview: some View {
        if let lastTextInsertion = appState.lastTextInsertion {
            Text(lastTextInsertion.summaryText)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            Text(lastTextInsertion.method.detailText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let lastTranscription = appState.lastTranscription {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "\(lastTranscription.taskMode.title) / \(lastTranscription.detectedLanguageDisplayName)",
                    systemImage: "text.bubble.fill"
                )
                .font(.system(size: 12, weight: .semibold))

                if lastTranscription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Whisper finished, but returned an empty transcript.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(lastTranscription.text)
                        .font(.system(size: 12))
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("\(lastTranscription.segments.count) segment\(lastTranscription.segments.count == 1 ? "" : "s") completed at \(lastTranscription.completedAt.formatted(date: .omitted, time: .standard)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let lastCapture = appState.lastCapture {
            Text("Last capture: \(lastCapture.durationText)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            Text("No transcript captured yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct MenuBarIconView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        Image(systemName: appState.menuBarIconName)
            .accessibilityLabel("DictaFlow")
    }
}

private struct MenuPanelSection<Content: View>: View {
    var title: String?
    var systemImage: String?
    var isWarning = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title, let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isWarning ? .orange : .secondary)
            }

            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isWarning ? Color.orange.opacity(0.38) : Color.cyan.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct MissingSettingRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 18

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
