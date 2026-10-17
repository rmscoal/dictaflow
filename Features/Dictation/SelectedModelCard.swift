import SwiftUI

struct SelectedModelCard: View {
    let name: String
    let providerAsset: String?
    let status: String
    let size: String
    var hasError = false
    var actionTitle = "Change…"
    var disabled = false
    let action: () -> Void

    var body: some View {
        EmberPanel {
            HStack(spacing: 13) {
                if let providerAsset { EmberProviderIcon(asset: providerAsset, size: 46) }
                else { Image(systemName: "archivebox").frame(width: 46, height: 46) }
                Text(name).font(.system(size: 20, weight: .medium))
                Spacer(minLength: 5)
                Button(actionTitle, action: action).buttonStyle(EmberButtonStyle()).disabled(disabled)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            EmberDivider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    statusLabel
                    Text("·").foregroundStyle(AppTheme.secondaryText)
                    Text(size).foregroundStyle(AppTheme.secondaryText)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 5) {
                    statusLabel
                    Text(size).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.background, in: Rectangle())
        }
    }

    private var statusLabel: some View {
        Label(status, systemImage: hasError ? "exclamationmark.circle" : "checkmark")
            .foregroundStyle(hasError ? AppTheme.errorText : AppTheme.modelActive)
    }
}
