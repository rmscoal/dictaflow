import SwiftUI

struct DictationStageCard: View {
    let tab: DictationSettingsTab
    let index: Int
    let value: String
    let detail: String
    let providerAsset: String?
    let selected: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 4) {
                    Text("0\(index) / \(tab.title)").font(.system(size: 11))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "chevron.down" : "chevron.right").font(.system(size: 10))
                }
                .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondaryText)
                HStack(spacing: compact ? 8 : 11) {
                    if let providerAsset { EmberProviderIcon(asset: providerAsset, size: compact ? 24 : 32) }
                    else { EmberAppMark(size: compact ? 24 : 32) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(value).font(.system(size: compact ? 12 : 14, weight: .medium))
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, compact ? 12 : 18).padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: compact ? 92 : 98, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? AppTheme.selectedFill : AppTheme.tileFill,
                        in: RoundedRectangle(cornerRadius: compact ? 17 : 21, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 17 : 21, style: .continuous)
                    .stroke(selected ? AppTheme.accent : AppTheme.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 21))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([tab.title, value, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("stage-\(tab.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
