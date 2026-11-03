import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState

    @State private var deletionCandidates: [LocalModelFile] = []
    @State private var confirmsCleanup = false

    var body: some View {
        EmberColumns(ratio: 1.15, gap: 26) {
            VStack(alignment: .leading, spacing: 0) {
                EmberModuleHeading(title: "Shortcuts & audio")
                EmberSectionHeading(title: "Global shortcut")
                GlobalShortcutSettingsContent(appState: appState)
                    .padding(.bottom, 18)
                EmberSectionHeading(title: "During recording")
                EmberPanel {
                    EmberRow(title: "System audio") {
                        Picker("System audio during recording", selection: Binding(
                            get: { appState.recordingPlaybackBehavior },
                            set: { appState.updateRecordingPlaybackBehavior($0) }
                        )) {
                            Text("Unchanged").tag(RecordingPlaybackBehavior.unchanged)
                            Text("Lower").tag(RecordingPlaybackBehavior.lowerSystemVolume)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 157)
                        .disabled(appState.whisperSettingsLocked)
                    }
                    EmberDivider()
                    EmberRow(title: "Pause supported apps") {
                        Text("Coming soon").font(.system(size: 11))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                EmberModuleHeading(title: "Storage")
                EmberPanel {
                    EmberRow(title: "Models", detail: "\(appState.formattedLocalModelSize(appState.installedLocalModelFiles.reduce(0) { $0 + $1.byteCount })) stored") {
                        Button { appState.openModelsFolder() } label: {
                            Label("Open storage folder", systemImage: "folder")
                        }
                        .buttonStyle(EmberButtonStyle())
                    }
                    EmberDivider()
                    ForEach(appState.installedLocalModelFiles) { file in
                        EmberRow(title: file.displayName, detail: "\(file.category.title) · \(appState.isActiveLocalModelFile(file) ? "Selected" : "Unused")", asset: file.providerAssetName) {
                            Text(appState.formattedLocalModelSize(file.byteCount))
                                .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        }
                        EmberDivider()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(appState.modelStorageStatusText)
                            .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        Button(appState.isDeletingModel ? "Removing models…" : "Delete unused models…") {
                            deletionCandidates = appState.unusedLocalModelFiles
                            confirmsCleanup = true
                        }
                        .buttonStyle(EmberButtonStyle())
                        .disabled(!appState.canReviewUnusedModelDeletion)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        .onAppear { appState.refreshInstalledLocalModelFiles() }
        .alert("Delete Unused Models?", isPresented: $confirmsCleanup) {
            Button("Cancel", role: .cancel) { deletionCandidates = [] }
            Button("Delete", role: .destructive) {
                appState.deleteUnusedModelFiles(matching: deletionCandidates)
                deletionCandidates = []
            }
            .disabled(!appState.canReviewUnusedModelDeletion)
        } message: {
            Text(cleanupConfirmation)
        }
        .onDisappear { appState.cancelGlobalShortcutEditing() }
    }

    private var cleanupConfirmation: String {
        let files = deletionCandidates.map {
            "\($0.category.title): \($0.displayName) (\(appState.formattedLocalModelSize($0.byteCount)))"
        }.joined(separator: "\n")
        let size = appState.formattedLocalModelSize(deletionCandidates.reduce(0) { $0 + $1.byteCount })
        return "This permanently deletes:\n\(files)\n\nSpace to free: \(size). Selected models and saved history are kept."
    }
}
