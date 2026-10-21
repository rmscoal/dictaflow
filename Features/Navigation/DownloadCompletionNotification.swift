import SwiftUI

/// In-app download completion notification, in the style of a transient
/// notification card: it appears at the top right of the main window,
/// can be closed early, and otherwise dismisses itself shortly after
/// the user returns to DictaFlow.
struct DownloadCompletionNotification: View {
    @ObservedObject var appState: DictaFlowAppState
    let notice: DownloadCompletionNotice

    var body: some View {
        let failed = notice.kind == .failed
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(failed ? AppTheme.errorText : AppTheme.modelActive)
                .accessibilityHidden(true)

            Button {
                appState.dismissDownloadCompletionNotice()
                appState.openDownloadActivity(notice.activity)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.title).font(.system(size: 13, weight: .semibold))
                    Text(notice.message)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(notice.title). \(notice.message)")

            Button { appState.dismissDownloadCompletionNotice() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(EmberIconButtonStyle())
            .help("Dismiss notification")
            .accessibilityLabel("Dismiss notification")
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(failed ? AppTheme.errorBorder : AppTheme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download-completion-notification")
    }
}
