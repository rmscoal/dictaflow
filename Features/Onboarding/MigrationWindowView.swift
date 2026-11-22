import SwiftUI

struct MigrationWindowState {
    enum Stage: Int {
        case preparing, copyingData, checkingSpeechModels, openingStores, copyingOfflineModels
    }

    var stage: Stage?
    var resuming = false
    var copiesOnlyOfflineModels = false
    var speechModelsIncomplete = false
    var isComplete = false
    var error: String?
    var revealLocation: URL?

    var canClose: Bool { isComplete || error != nil }
}

struct MigrationWindowView: View {
    @ObservedObject var delegate: DictaFlowAppDelegate

    var body: some View {
        if let state = delegate.migration {
            VStack(spacing: 22) {
                HStack(spacing: 9) {
                    EmberAppMark(size: 36)
                    Text("Omdo").font(.system(size: 21, weight: .semibold, design: .rounded))
                }

                VStack(spacing: 7) {
                    Text(state.stage == nil && state.error != nil ? "Omdo could not open its local data" : "DictaFlow is now Omdo")
                        .font(.system(size: 25, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if state.stage != nil {
                        Text(subtitle(for: state))
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 12) {
                    if let stage = state.stage {
                        VStack(spacing: 0) {
                            if !state.copiesOnlyOfflineModels {
                                step(.copyingData, "Copy local data", state: state)
                                EmberDivider()
                                step(.checkingSpeechModels, "Check existing speech models", state: state)
                                EmberDivider()
                                step(.openingStores, "Open migrated data", state: state)
                            }
                            if stage == .copyingOfflineModels {
                                if !state.copiesOnlyOfflineModels { EmberDivider() }
                                step(.copyingOfflineModels, "Copy offline dictation models", state: state)
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(AppTheme.border.opacity(0.55)) }
                    }
                    if let detail = state.error {
                        EmberWarningLabel(detail).textSelection(.enabled)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if state.isComplete {
                        if state.speechModelsIncomplete {
                            EmberWarningLabel("Some speech model files couldn’t be reused. Check the model in Agent Voice.")
                                .font(.system(size: 12))
                        }
                        if let notice = delegate.modelMigrationNotice {
                            EmberWarningLabel(notice)
                                .font(.system(size: 12))
                        }
                        Text("Your original DictaFlow data is still on this Mac.")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    } else if state.stage == .checkingSpeechModels || state.stage == .copyingOfflineModels {
                        Text("Omdo is checking model files already on this Mac. This may take a moment.")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    if !state.isComplete {
                        Button("Quit Omdo") { NSApp.terminate(nil) }
                            .buttonStyle(SecondaryOnboardingButtonStyle())
                    }
                    Spacer()
                    if let location = state.revealLocation {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                            .buttonStyle(SecondaryOnboardingButtonStyle())
                    }
                    Button(state.error == nil ? "Continue" : "Try again") {
                        if state.isComplete { delegate.continueAfterMigration() }
                        else { delegate.prepareApplication() }
                    }
                    .buttonStyle(PrimaryOnboardingButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.isComplete && state.error == nil)
                }
            }
            .padding(.horizontal, 42)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(width: 620)
            .foregroundStyle(AppTheme.primaryText)
            .background(AppTheme.background)
        }
    }

    private func subtitle(for state: MigrationWindowState) -> String {
        if state.error != nil { return "Omdo paused the upgrade." }
        if state.isComplete { return "Your local data is ready to use in Omdo." }
        if state.resuming { return "Omdo is resuming your upgrade." }
        if state.copiesOnlyOfflineModels { return "Omdo is bringing your offline dictation models over automatically." }
        return "Omdo is bringing your local data and models over automatically."
    }

    private func step(_ step: MigrationWindowState.Stage, _ title: String, state: MigrationWindowState) -> some View {
        let current = state.stage == .preparing ? .copyingData : state.stage
        let active = !state.isComplete && current == step
        let done = state.isComplete || (current?.rawValue ?? 0) > step.rawValue
        let needsAttention = active && state.error != nil
            || step == .copyingOfflineModels && state.isComplete && delegate.modelMigrationNotice != nil
            || step == .checkingSpeechModels && done && state.speechModelsIncomplete
        let status = if needsAttention { state.isComplete ? "Needs attention" : "Paused" }
            else if done { "Done" }
            else if active {
                switch state.stage {
                case .preparing: "Preparing…"
                case .checkingSpeechModels: "Checking…"
                case .openingStores: "Opening…"
                default: "Copying…"
                }
            } else { "Waiting" }
        return HStack(spacing: 11) {
            Group {
                if needsAttention { EmberWarningIcon() }
                else if active { ProgressView().controlSize(.small).accessibilityHidden(true) }
                else { Image(systemName: done ? "checkmark.circle.fill" : "circle").accessibilityHidden(true) }
            }
            .frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(status).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}
