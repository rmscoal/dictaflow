import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            shortcutSection
            recordSection
            modelSection

            Divider()

            HStack(spacing: 8) {
                Button {
                    appState.showMainWindow()
                } label: {
                    Label("Show Main Application", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    appState.quit()
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .foregroundStyle(MenuTheme.primaryText)
        .background(MenuTheme.background)
    }

    private var shortcutSection: some View {
        MenuGlassTile {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MenuTheme.secondaryText)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Global Shortcut")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MenuTheme.secondaryText)

                    Text(appState.hotkeyDisplayText)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }

                Spacer()
            }
        }
    }

    private var recordSection: some View {
        MenuGlassTile {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: appState.dictationActionSymbolName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(appState.recordingState.isRecording ? .red : Color.accentColor)
                        .symbolRenderingMode(.hierarchical)

                    Text(appState.recordingState.isRecording ? "Recording" : "Ready")
                        .font(.system(size: 16, weight: .semibold))

                    Spacer()
                }

                Button {
                    appState.toggleDictation()
                } label: {
                    Label(appState.dictationActionTitle, systemImage: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(appState.recordingState.isRecording ? .red : Color.accentColor)
                .disabled(appState.transcriptionState.isTranscribing || appState.textInsertionState.isBusy)
            }
        }
    }

    private var modelSection: some View {
        MenuGlassTile {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Model")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MenuTheme.secondaryText)

                    Text(appState.whisperConfiguration.model.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }

                Spacer()

                Text(appState.whisperConfiguration.model.approximateDiskSizeDescription)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(MenuTheme.secondaryText)
            }
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

private struct MenuGlassTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MenuTheme.tileFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(MenuTheme.border, lineWidth: 1)
            )
    }
}

private enum MenuTheme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.064)
    static let tileFill = Color(red: 0.095, green: 0.098, blue: 0.108)
    static let border = Color.white.opacity(0.10)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.60)
}
