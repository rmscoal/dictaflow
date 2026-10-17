import SwiftUI

struct PermissionsSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.microphonePermissionState == .denied || appState.microphonePermissionState == .restricted {
                EmberErrorBanner(title: "Microphone access is blocked", message: appState.microphonePermissionState.detailText)
                    .padding(.bottom, 20)
            }
            EmberSectionHeading(title: "System permissions")
            EmberPanel {
                permissionRow(title: "Microphone", detail: "Voice recording", symbol: "mic",
                              status: appState.microphonePermissionState.title,
                              allowed: appState.microphonePermissionState == .granted,
                              action: appState.openMicrophoneSettings)
                EmberDivider()
                permissionRow(title: "Accessibility", detail: "Automatic text insertion", symbol: "shield.lefthalf.filled",
                              status: appState.accessibilityPermissionState.title,
                              allowed: appState.accessibilityPermissionState == .granted,
                              action: appState.openAccessibilitySettings)
            }
        }
        .onAppear {
            appState.refreshMicrophonePermissionStatus()
            appState.refreshAccessibilityPermissionStatus()
        }
    }

    private func permissionRow(title: String, detail: String, symbol: String, status: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15))
                    .frame(width: 34, height: 34)
                    .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if allowed {
                    Label(status, systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(AppTheme.modelActive)
                } else {
                    Button("Open System Settings…", action: action).buttonStyle(EmberButtonStyle())
                        .accessibilityLabel("Open \(title) settings. \(status)")
                }
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
        }
        .padding(20)
    }
}
