import SwiftUI

struct RefinementSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var instructionsExpanded = false
    @State private var preview = false
    @State private var confirmsPromptReset = false
    private var model: RefinementModelDescriptor { appState.refinementConfiguration.model }
    private var mode: RefinementMode { appState.refinementConfiguration.mode }
    private var unavailable: Bool { !appState.isRefinementRuntimeAvailable || !appState.isSelectedRefinementModelSupported }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberPanel {
                EmberRow(title: "Refine before insertion") {
                    Toggle("Refine before insertion", isOn: Binding(
                        get: { appState.refinementConfiguration.isEnabled }, set: { appState.updateRefinementEnabled($0) }
                    )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .disabled(appState.refinementSettingsLocked)
                }
            }
            .padding(.bottom, 18)
            if unavailable {
                EmberErrorBanner(title: "Refinement is unavailable", message: appState.refinementModelSupport(for: model).unsupportedReason ?? "Reinstall DictaFlow to restore local refinement. Dictation still works with your selected tone.")
                    .padding(.bottom, 18)
            } else if !appState.isSelectedRefinementModelPrepared {
                EmberErrorBanner(title: "Refinement model needs a download", message: "Dictation still works with your selected tone.", actionTitle: "Choose a refinement model") {
                    appState.showRefinementModels(focusing: model)
                }
                .padding(.bottom, 18)
            }
            EmberSectionHeading(title: "Refinement model")
            SelectedModelCard(name: model.displayName, providerAsset: model.provider?.iconName,
                              status: unavailable ? "Unavailable" : appState.isSelectedRefinementModelPrepared ? "Ready" : "Download needed",
                              size: model.approximateDiskSizeDescription,
                              hasError: unavailable || !appState.isSelectedRefinementModelPrepared,
                              disabled: appState.refinementSettingsLocked) {
                appState.showRefinementModels()
            }
            .padding(.bottom, 18)
            EmberPanel {
                EmberRow(title: "Writing style") {
                    Picker("Refinement writing style", selection: Binding(get: { mode }, set: { appState.updateRefinementMode($0) })) {
                        ForEach(RefinementMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 195).disabled(appState.refinementSettingsLocked)
                }
            }
            .padding(.bottom, 18)
            if mode == .diy {
                diyEditor
            } else {
                EmberPanel {
                    DisclosureGroup(isExpanded: $instructionsExpanded) {
                        instructionsEditor.padding(.top, 14)
                    } label: {
                        HStack {
                            Text("Additional instructions")
                            Spacer()
                            Text("Optional").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .disclosureGroupStyle(EmberDisclosureGroupStyle())
                    .font(.system(size: 12)).padding(17)
                }
            }
            if let error = appState.refinementWritingError {
                EmberErrorBanner(title: "Could not save instructions", message: error).padding(.top, 14)
            }
        }
        .onAppear { if appState.isPresetInstructionsDirty { instructionsExpanded = true } }
        .alert("Reset the system prompt?", isPresented: $confirmsPromptReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { appState.resetActiveRefinementPrompt() }
        } message: {
            Text("This restores the built-in DIY prompt and replaces its saved text and unsaved changes. Additional instructions for other writing styles are kept.")
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: Binding(get: { appState.currentPresetInstructions }, set: { appState.updatePresetInstructions($0) }))
                .font(.system(size: 12)).scrollContentBackground(.hidden)
                .frame(height: 100).padding(10)
                .background(AppTheme.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border, lineWidth: 1) }
                .disabled(appState.refinementSettingsLocked)
                .accessibilityLabel("Additional refinement instructions")
            HStack {
                Text(appState.isPresetInstructionsDirty ? "Unsaved changes" : "Saved")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Button("Save") { appState.savePresetInstructions() }
                    .buttonStyle(EmberButtonStyle())
                    .disabled(appState.refinementSettingsLocked || !appState.isPresetInstructionsDirty)
            }
        }
    }

    private var diyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                EmberSectionHeading(title: "System prompt")
                Spacer()
                Text("Markdown").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                Menu {
                    Button("Reset to default…") { confirmsPromptReset = true }
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 25) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(appState.refinementSettingsLocked)
                .accessibilityLabel("System prompt actions")
            }
            Picker("Prompt editor mode", selection: $preview) {
                Text("Write").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            Group {
                if preview {
                    ScrollView { MarkdownPromptPreview(source: appState.refinementPromptText).frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }
                } else {
                    TextEditor(text: Binding(get: { appState.refinementPromptText }, set: { appState.updateRefinementPromptText($0) }))
                        .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(10)
                        .disabled(appState.refinementSettingsLocked)
                        .accessibilityLabel("System prompt in Markdown")
                }
            }
            .frame(height: 280)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border, lineWidth: 1) }
            HStack {
                Text(appState.isRefinementPromptDirty ? "Unsaved changes" : "Saved")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Button("Save prompt") { appState.saveRefinementPromptText() }
                    .buttonStyle(EmberButtonStyle())
                    .disabled(appState.refinementSettingsLocked || !appState.isRefinementPromptDirty || appState.refinementPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
