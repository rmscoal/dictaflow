import SwiftUI

struct GlobalShortcutSettingsContent: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Global Shortcut", systemImage: "keyboard")
                    .font(.headline)

                Spacer(minLength: 10)

                if !appState.isEditingGlobalShortcut {
                    Text(appState.hotkeyDisplayText)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if appState.isEditingGlobalShortcut {
                Text("Press a shortcut with Command, Control, Option, or Shift. Escape cancels.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.28), lineWidth: 0.75)
                        }

                    Text("Press a shortcut…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)

                    GlobalShortcutCaptureView(
                        isCapturing: true,
                        onShortcut: { appState.handleGlobalShortcutCandidate($0) },
                        onCancel: { appState.cancelGlobalShortcutEditing() }
                    )
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .opacity(0.01)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 42)

                if let message = appState.globalShortcutEditingMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Cancel", role: .cancel) {
                    appState.cancelGlobalShortcutEditing()
                }
                .buttonStyle(.bordered)
            } else {
                HStack(spacing: 12) {
                    Text(appState.hotkeyDisplayText)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))

                    Spacer(minLength: 10)

                    Button("Change Shortcut") {
                        appState.beginGlobalShortcutEditing()
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.whisperSettingsLocked)
                }

                Text("Use this shortcut to start or stop recording from any app.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
