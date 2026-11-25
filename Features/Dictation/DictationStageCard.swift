import SwiftUI

struct DictationStageCard: View {
    let tab: DictationSettingsTab
    let value: String
    let detail: String
    let providerAsset: String?
    let selected: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 4) {
                    Text(tab.title).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "chevron.down" : "chevron.right").font(.system(size: 10))
                }
                .foregroundStyle(AppTheme.primaryText)
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
            .padding(.horizontal, compact ? 12 : 15).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: compact ? 80 : 86, maxHeight: .infinity, alignment: .topLeading)
            .omdoSelectionBackground(in: shape, isSelected: selected)
            .contentShape(shape)
        }
        .buttonStyle(EmberButtonStyle(appearance: .plain))
        .accessibilityLabel([tab.title, value, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("stage-\(tab.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
