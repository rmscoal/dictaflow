import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: DictaFlowAppState

    private let statusColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection

            LazyVGrid(columns: statusColumns, spacing: 16) {
                StatusCard(
                    title: "Global Shortcut",
                    systemImage: "command.square",
                    content: "\(appState.hotkeyDisplayText)\n\(appState.isHotkeyRegistered ? "Registered and ready system-wide." : "Registration failed. Keep the window open to troubleshoot.")"
                )

                StatusCard(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    content: "\(appState.microphonePermissionState.title)\n\(appState.microphonePermissionState.detailText)"
                )

                StatusCard(
                    title: "Accessibility",
                    systemImage: "figure.wave.circle",
                    content: "\(appState.accessibilityPermissionState.title)\n\(appState.accessibilityPermissionState.detailText)"
                )

                StatusCard(
                    title: "Whisper Model",
                    systemImage: "externaldrive.fill.badge.checkmark",
                    content: "\(appState.whisperConfiguration.model.displayName)\n\(appState.modelStatusText)"
                )
            }

            GroupBox("Dictation Control") {
                VStack(alignment: .leading, spacing: 14) {
                    Label(appState.dictationSummaryText, systemImage: appState.dictationActionSymbolName)
                        .font(.headline)

                    Text(appState.statusMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(appState.dictationActionTitle) {
                            appState.toggleDictation()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(appState.recordingState.isRecording ? .red : .accentColor)

                        Button("Insert Last Transcript Again") {
                            appState.insertLastTranscription()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!appState.canInsertLastTranscription)

                        Button("Copy Last Transcript") {
                            appState.copyLastTranscription()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!appState.canCopyLastTranscription)
                    }

                    HStack(spacing: 12) {
                        Button("Refresh Microphone Status") {
                            appState.refreshMicrophonePermissionStatus()
                        }
                        .buttonStyle(.bordered)

                        Button("Refresh Accessibility Status") {
                            appState.refreshAccessibilityPermissionStatus()
                        }
                        .buttonStyle(.bordered)

                        Button("Open Accessibility Settings") {
                            appState.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)

                        Button("Retry Model Preparation") {
                            appState.retryModelPreparation()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            GroupBox("Text Insertion") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(appState.textInsertionStatusText, systemImage: "text.cursor")
                        .font(.headline)

                    if let lastTextInsertion = appState.lastTextInsertion {
                        Text(lastTextInsertion.method.title)
                            .font(.subheadline.weight(.semibold))

                        Text(lastTextInsertion.method.detailText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("After transcription finishes, DictaFlow will automatically target the current app with the configured fallback chain.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            if let lastTranscription = appState.lastTranscription {
                GroupBox("Last Local Transcript") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            "\(lastTranscription.taskMode.title) • \(lastTranscription.detectedLanguageDisplayName)",
                            systemImage: "text.bubble.fill"
                        )
                        .font(.headline)

                        Text(lastTranscription.text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Completed at \(lastTranscription.completedAt.formatted(date: .abbreviated, time: .standard)) using \(lastTranscription.model.displayName).")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }

            if let lastCapture = appState.lastCapture {
                GroupBox("Last Local Capture") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Saved at \(lastCapture.capturedAt.formatted(date: .abbreviated, time: .standard))", systemImage: "waveform.path")
                            .font(.headline)

                        Text("Duration: \(lastCapture.durationText)")
                            .foregroundStyle(.secondary)

                        Text(lastCapture.fileURL.path)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Hide Window") {
                    appState.closeMainWindow()
                }

                Spacer()

                Text(appState.launchBehaviorText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DictaFlow")
                .font(.system(size: 28, weight: .semibold))

            Text("Local-first voice dictation for macOS")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(appState.launchExperience.headline)
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Phase 4 adds focused-app text insertion with Accessibility permission handling and a full fallback chain for paste, simulated typing, and manual copy.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusCard: View {
    let title: String
    let systemImage: String
    let content: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)

                Text(content)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
