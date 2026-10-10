import SwiftUI

struct RefinementSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var selectedTab = 0
    @State private var provider: RefinementProvider = .qwen
    @State private var preview = false
    @State private var savedMode: RefinementMode?

    private var model: RefinementModelDescriptor { appState.refinementConfiguration.model }
    private var mode: RefinementMode { appState.refinementConfiguration.mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Refine before insertion").font(.headline)
                Spacer()
                Toggle("Refine before insertion", isOn: Binding(
                    get: { appState.refinementConfiguration.isEnabled },
                    set: { appState.updateRefinementEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(appState.refinementSettingsLocked)
            }
            HStack(spacing: 10) {
                ProviderIcon(provider: model.provider)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected model").font(.caption).foregroundStyle(AppTheme.secondaryText)
                    Text(model.displayName).fontWeight(.semibold)
                    Text(mode.title).font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Text(!appState.isSelectedRefinementModelSupported ? "Unavailable" : (appState.isSelectedRefinementModelPrepared ? "Ready locally" : "Download needed"))
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            .padding(16).background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border))

            sectionTabs

            ForEach(appState.visibleRefinementDownloadModels.filter { selectedTab != 0 || $0.provider != provider }, id: \.self) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.displayName).font(.caption).fontWeight(.medium)
                        Spacer()
                        if appState.isDownloadingRefinementModel(item) {
                            Button("Cancel") { appState.cancelRefinementModelDownload(item) }.controlSize(.small)
                        } else {
                            Button("Show model") { selectedTab = 0; provider = item.provider }.controlSize(.small)
                        }
                    }
                    if appState.isDownloadingRefinementModel(item) {
                        ProgressView(value: appState.refinementDownloadProgress(for: item) ?? 0)
                    }
                    Text(appState.refinementDownloadError(for: item) ?? appState.refinementDownloadStatusText(for: item))
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }.padding(10).background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 7))
            }
            Group {
                if selectedTab == 0 { models } else { writingStyle }
            }.padding(.top, 6)
        }
        .foregroundStyle(AppTheme.primaryText)
        .onAppear { provider = model.provider }
    }

    private var sectionTabs: some View {
        HStack(spacing: 24) {
            ForEach(0..<2) { tab in
                Button { selectedTab = tab } label: {
                    Text(tab == 0 ? "Models" : "Writing style")
                        .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? AppTheme.primaryText : AppTheme.secondaryText)
                        .padding(.top, 4).padding(.bottom, 12)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selectedTab == tab ? AppTheme.accent : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
            Spacer()
        }
        .background(alignment: .bottom) { Rectangle().fill(AppTheme.border).frame(height: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("Refinement settings")
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                providerTabs(compact: false)
                providerTabs(compact: true)
            }
            VStack(spacing: 8) {
                ForEach(RefinementModelDescriptor.allCases.filter { $0.provider == provider }, id: \.self) { item in
                    modelRow(item)
                }
            }
            if provider == .meta {
                HStack {
                    Text("Built with Llama")
                    Spacer()
                    Link("Llama 3.2 license", destination: URL(string: "https://www.llama.com/llama3_2/license/")!)
                }.font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            if !appState.isRefinementRuntimeAvailable {
                Text("Local runtime unavailable. Reinstall DictaFlow to restore llama-server.")
                    .font(.caption).foregroundStyle(AppTheme.warning)
            }
        }
    }

    private func providerTabs(compact: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(RefinementProvider.allCases) { item in
                Button { provider = item } label: {
                    HStack(spacing: 5) {
                        ProviderIcon(provider: item, size: 20)
                        Text(compact ? item.compactTitle : item.title)
                            .font(.system(size: 11, weight: .medium)).fixedSize()
                    }.padding(.horizontal, 9).padding(.vertical, 8)
                        .foregroundStyle(provider == item ? AppTheme.accent : AppTheme.primaryText)
                        .background(provider == item ? AppTheme.accent.opacity(0.12) : AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(provider == item ? AppTheme.accent : AppTheme.border))
                }.buttonStyle(.plain).accessibilityLabel(item.title)
            }
        }.padding(1).fixedSize(horizontal: true, vertical: false)
    }

    private func modelRow(_ item: RefinementModelDescriptor) -> some View {
        let downloading = appState.isDownloadingRefinementModel(item)
        let prepared = appState.isRefinementModelPrepared(item)
        let error = appState.refinementDownloadError(for: item)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ProviderIcon(provider: item.provider)
                VStack(alignment: .leading, spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            modelName(item)
                            Text(item.approximateDiskSizeDescription)
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) {
                            modelName(item)
                            Text(item.approximateDiskSizeDescription)
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text(item.quantization)
                            Text(item.estimatedRuntimeMemoryDescription)
                        }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.quantization)
                            Text(item.estimatedRuntimeMemoryDescription)
                        }
                    }.font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 8)
                if downloading {
                    Button("Cancel") { appState.cancelRefinementModelDownload(item) }
                        .controlSize(.small)
                } else if prepared && item == model {
                    Text("Active").font(.caption).foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Button(prepared ? "Use model" : (error == nil ? "Download" : "Retry")) {
                        if prepared { appState.updateRefinementModel(item) }
                        else { appState.downloadRefinementModel(item) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(AppTheme.accent)
                    .disabled(appState.refinementSettingsLocked || !appState.isRefinementModelSupported(item) || !appState.isRefinementRuntimeAvailable)
                }
            }
            if downloading {
                if let value = appState.refinementDownloadProgress(for: item) { ProgressView(value: value) }
                else { ProgressView().controlSize(.small) }
                Text(appState.refinementDownloadStatusText(for: item))
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            if let error { Text(error).font(.caption).foregroundStyle(AppTheme.warning).textSelection(.enabled) }
            if let reason = appState.refinementModelSupport(for: item).unsupportedReason {
                Text(reason).font(.caption).foregroundStyle(AppTheme.warning)
            }
        }
        .padding(15)
        .background(item == model ? AppTheme.accent.opacity(0.07) : AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(item == model ? AppTheme.accent.opacity(0.5) : AppTheme.border))
    }

    private func modelName(_ item: RefinementModelDescriptor) -> some View {
        Text(item.displayName).font(.system(size: 14, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var writingStyle: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Writing mode").fontWeight(.semibold)
                Spacer()
                Picker("Writing mode", selection: Binding(get: { mode }, set: { appState.updateRefinementMode($0) })) {
                    ForEach(RefinementMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: 285).disabled(appState.refinementSettingsLocked)
            }
            Spacer().frame(height: 36)
            if mode == .diy {
                diyEditor
            } else {
                presetInstructions
                writingExample.padding(.top, 18)
            }
            if let error = appState.refinementWritingError {
                Text(error).font(.caption).foregroundStyle(AppTheme.warning).padding(.top, 14)
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle().fill(AppTheme.border).frame(height: 1).accessibilityHidden(true)
    }

    private var diyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System prompt").fontWeight(.semibold)
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 4) {
                        editorTab("Write", isPreview: false)
                        editorTab("Preview", isPreview: true)
                    }
                    Spacer()
                    Text("Markdown").font(.caption).foregroundStyle(AppTheme.secondaryText)
                }.padding(.horizontal, 12).padding(.vertical, 9)
                sectionDivider
                if preview {
                    MarkdownPromptPreview(source: appState.refinementPromptText)
                        .frame(maxWidth: .infinity, minHeight: 305, alignment: .topLeading)
                        .padding(16)
                } else {
                    TextEditor(text: Binding(get: { appState.refinementPromptText }, set: { appState.updateRefinementPromptText($0) }))
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden).frame(height: 305).padding(12)
                        .disabled(appState.refinementSettingsLocked)
                        .accessibilityLabel("System prompt in Markdown")
                }
            }
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border))
            HStack {
                Text(appState.isRefinementPromptDirty ? "Unsaved changes" : "Saved")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Button("Save prompt") { appState.saveRefinementPromptText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.refinementSettingsLocked || !appState.isRefinementPromptDirty || appState.refinementPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func editorTab(_ title: String, isPreview: Bool) -> some View {
        Button { preview = isPreview } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(preview == isPreview ? AppTheme.accent : AppTheme.secondaryText)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(preview == isPreview ? AppTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(preview == isPreview ? .isSelected : [])
    }

    private var presetInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Additional instructions").fontWeight(.medium)
                Text("Optional").font(.caption).foregroundStyle(AppTheme.secondaryText)
                Spacer()
            }
            ZStack(alignment: .topLeading) {
                editor(Binding(get: { appState.currentPresetInstructions }, set: { appState.updatePresetInstructions($0) }), height: 85)
                    .accessibilityLabel("Additional instructions")
                if appState.currentPresetInstructions.isEmpty {
                    Text("Keep paragraphs short. Avoid emojis.").font(.system(size: 12))
                        .foregroundStyle(AppTheme.tertiaryText).padding(.horizontal, 13).padding(.top, 13)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            HStack {
                if appState.isPresetInstructionsDirty {
                    Text("Unsaved changes").font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                if savedMode == mode && !appState.isPresetInstructionsDirty {
                    Text("Saved").font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Button("Save") {
                    appState.savePresetInstructions()
                    if appState.refinementWritingError == nil { savedMode = mode }
                }
                .buttonStyle(.bordered)
                .disabled(appState.refinementSettingsLocked || !appState.isPresetInstructionsDirty)
            }
        }
    }

    private var writingExample: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Writing Example").fontWeight(.semibold)
                Spacer()
                Text("Static example").font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            Text("Before").font(.caption).foregroundStyle(AppTheme.secondaryText).padding(.top, 15)
            Text("Hey um can you review the auth PR by Wednesday? I think it might fix the login issue but yeah we still need to test it.")
                .foregroundStyle(AppTheme.secondaryText).padding(.top, 9)
            sectionDivider.padding(.top, 17).padding(.bottom, 15)
            Text("After").font(.caption).foregroundStyle(AppTheme.secondaryText)
            Text(mode.writingExample).padding(.top, 9)
        }.font(.system(size: 12)).lineSpacing(4).padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border))
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden).frame(height: height).padding(8)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppTheme.border))
            .disabled(appState.refinementSettingsLocked)
    }
}

private struct ProviderIcon: View {
    let provider: RefinementProvider
    var size: CGFloat = 28
    var body: some View {
        Image(provider.iconName).resizable().scaledToFit().padding(3)
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}

/// Display common Markdown blocks with native text. Raw HTML remains inert text.
/// Parsing is only for preview; the original source is saved and sent unchanged.
private struct MarkdownPromptPreview: View {
    let source: String
    private struct Block: Identifiable {
        let id: Int
        let text: String
        let heading: Int
        let isCode: Bool
        let isBullet: Bool
    }
    private var blocks: [Block] {
        var result: [Block] = []
        var code = false
        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") { code.toggle(); continue }
            let heading = code ? 0 : line.prefix(while: { $0 == "#" }).count
            let isHeading = (1...6).contains(heading) && line.dropFirst(heading).hasPrefix(" ")
            let bullet = !code && line.hasPrefix("- ")
            let text = isHeading ? String(line.dropFirst(heading + 1)) : (bullet ? String(line.dropFirst(2)) : line)
            result.append(Block(id: result.count, text: text.isEmpty ? " " : text,
                                heading: isHeading ? heading : 0, isCode: code, isBullet: bullet))
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                HStack(alignment: .top, spacing: 6) {
                    if block.isBullet { Text("•") }
                    if block.isCode {
                        Text(block.text).font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4).background(AppTheme.controlFill)
                    } else {
                        Text((try? AttributedString(markdown: block.text,
                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                            .font(block.heading == 1 ? .title2 : (block.heading > 0 ? .headline : .body))
                    }
                }
            }
        }.textSelection(.enabled)
    }
}
