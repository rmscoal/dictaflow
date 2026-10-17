import SwiftUI

struct GlobalShortcutSettingsContent: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            EmberPanel {
                EmberRow(title: "Start or stop dictation") {
                    if appState.isEditingGlobalShortcut {
                        ZStack {
                            Text("Press shortcut…").font(.system(size: 12))
                            GlobalShortcutCaptureView(
                                isCapturing: true,
                                onShortcut: { appState.handleGlobalShortcutCandidate($0) },
                                onCancel: { appState.cancelGlobalShortcutEditing() }
                            )
                            .opacity(0.01).accessibilityHidden(true)
                        }
                        .frame(width: 134, height: 32)
                        .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).stroke(AppTheme.accent) }
                    } else {
                        Button { appState.beginGlobalShortcutEditing() } label: {
                            ShortcutKeycaps(shortcut: appState.globalShortcut)
                        }
                        .buttonStyle(EmberButtonStyle())
                        .disabled(appState.whisperSettingsLocked)
                        .accessibilityLabel("Change recording shortcut. \(appState.hotkeyDisplayText)")
                    }
                }
            }
            if appState.isEditingGlobalShortcut {
                HStack(alignment: .top, spacing: 12) {
                    Text(appState.globalShortcutEditingMessage ?? "Use Command, Control, Option, or Shift. Escape cancels.")
                        .foregroundStyle(appState.globalShortcutEditingMessage == nil ? AppTheme.secondaryText : AppTheme.errorText)
                    Spacer(minLength: 0)
                    Button("Cancel", role: .cancel) { appState.cancelGlobalShortcutEditing() }.buttonStyle(.plain)
                }
                .font(.system(size: 11))
            } else if !appState.isHotkeyRegistered {
                Text("Shortcut unavailable. Choose another key combination.")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.errorText)
            }
        }
    }
}
