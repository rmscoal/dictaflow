import SwiftUI

struct RefinementModelsView: View {
    @ObservedObject var appState: DictaFlowAppState
    @Binding var provider: RefinementProvider
    let downloadModel: (RefinementModelDescriptor) -> Void
    let removeModel: (RefinementModelDescriptor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                ForEach(RefinementProvider.allCases) { item in
                    Button { provider = item } label: {
                        HStack(spacing: 6) {
                            EmberProviderIcon(asset: item.iconName, size: 22)
                            Text(item.compactTitle).font(.system(size: 12))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle(provider == item ? AppTheme.accent : AppTheme.primaryText)
                        .background(provider == item ? AppTheme.selectedFill : AppTheme.tileFill, in: Capsule())
                        .overlay { Capsule().stroke(provider == item ? AppTheme.accent : AppTheme.border, lineWidth: 1) }
                    }
                    .buttonStyle(.plain).accessibilityLabel(item.title)
                    .accessibilityAddTraits(provider == item ? .isSelected : [])
                }
            }
            if !appState.isRefinementRuntimeAvailable {
                EmberErrorBanner(title: "Local runtime unavailable", message: "Reinstall DictaFlow to restore llama-server.")
            }
            VStack(spacing: 0) {
                ForEach(RefinementModelDescriptor.allCases.filter { $0.provider == provider }, id: \.self) { model in
                    modelRow(model).id(model.modelIdentifier)
                    EmberDivider()
                }
            }
        }
    }

    private func modelRow(_ model: RefinementModelDescriptor) -> some View {
        let prepared = appState.isRefinementModelPrepared(model)
        let downloading = appState.isDownloadingRefinementModel(model)
        let error = appState.refinementDownloadError(for: model)
        let unsupported = appState.refinementModelSupport(for: model).unsupportedReason
        let selected = model == appState.refinementConfiguration.model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                EmberProviderIcon(asset: provider.iconName, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.displayName).font(.system(size: 14, weight: .medium))
                    Text("\(model.approximateDiskSizeDescription) · \(model.quantization)").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    Text(model.estimatedRuntimeMemoryDescription).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    if downloading {
                        Button("Cancel") { appState.cancelRefinementModelDownload(model) }.buttonStyle(EmberButtonStyle())
                    } else if prepared && selected {
                        Label("Selected", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(AppTheme.accent)
                    } else if prepared {
                        Button("Use") { appState.updateRefinementModel(model) }.buttonStyle(EmberButtonStyle())
                            .disabled(appState.refinementSettingsLocked || unsupported != nil || !appState.isRefinementRuntimeAvailable)
                    } else {
                        Button(error == nil ? "Download" : "Retry") { downloadModel(model) }
                            .buttonStyle(EmberButtonStyle(primary: true))
                            .disabled(appState.refinementSettingsLocked || unsupported != nil || !appState.isRefinementRuntimeAvailable)
                    }
                    if prepared && !selected {
                        Button { removeModel(model) } label: { Image(systemName: "trash") }
                            .buttonStyle(EmberIconButtonStyle()).disabled(!appState.canDeleteRefinementModel(model))
                            .help("Remove \(model.displayName)").accessibilityLabel("Remove \(model.displayName)")
                    }
                }
            }
            if downloading {
                ProgressView(value: appState.refinementDownloadProgress(for: model)).tint(AppTheme.accent)
                Text(appState.refinementDownloadStatusText(for: model)).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(AppTheme.errorText).textSelection(.enabled) }
            if let unsupported { Text(unsupported).font(.system(size: 12)).foregroundStyle(AppTheme.errorText) }
        }
        .padding(.vertical, 17).padding(.horizontal, error != nil || unsupported != nil ? 12 : 0)
        .background(error != nil || unsupported != nil ? AppTheme.errorFill : .clear, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            if error != nil || unsupported != nil { RoundedRectangle(cornerRadius: 16).stroke(AppTheme.errorBorder, lineWidth: 1) }
        }
    }
}
