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
                        .contentShape(Capsule())
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
                        ModelCardActionGroup(
                            useDisabled: appState.refinementSettingsLocked || unsupported != nil || !appState.isRefinementRuntimeAvailable,
                            onUse: { appState.updateRefinementModel(model) },
                            removeDisabled: !appState.canDeleteRefinementModel(model),
                            onRemove: { removeModel(model) },
                            removeHelp: "Remove \(model.displayName)"
                        )
                    } else {
                        Button(error == nil ? "Download" : "Retry") { downloadModel(model) }
                            .buttonStyle(EmberButtonStyle(primary: true))
                            .disabled(appState.refinementSettingsLocked || unsupported != nil || !appState.isRefinementRuntimeAvailable)
                    }
                }
            }
            if downloading {
                EmberDownloadProgress(value: appState.refinementDownloadProgress(for: model))
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

/// Joined Use + remove control in the Ant Design button-group manner: two
/// segments sharing one border with the destructive segment in red. Kept
/// local to the refinement cards, where the red remove action was requested.
/// The separator is an overlay, not a layout member: a flexible divider in
/// the stack would stretch to the full row height and inflate the group.
struct ModelCardActionGroup: View {
    let useDisabled: Bool
    let onUse: () -> Void
    let removeDisabled: Bool
    let onRemove: () -> Void
    let removeHelp: String

    var body: some View {
        HStack(spacing: 0) {
            Button("Use", action: onUse)
                .buttonStyle(ModelCardSegmentStyle(horizontal: 12))
                .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.border).frame(width: 1) }
                .opacity(useDisabled ? 0.45 : 1)
                .disabled(useDisabled)
            Button(action: onRemove) { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(ModelCardSegmentStyle(horizontal: 10))
                .foregroundStyle(AppTheme.errorText)
                .opacity(removeDisabled ? 0.45 : 1)
                .disabled(removeDisabled)
                .help(removeHelp).accessibilityLabel(removeHelp)
        }
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.border, lineWidth: 1) }
    }
}

private struct ModelCardSegmentStyle: ButtonStyle {
    let horizontal: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontal).padding(.vertical, 7)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
