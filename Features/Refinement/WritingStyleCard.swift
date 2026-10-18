import SwiftUI

struct WritingStyleCard<Instructions: View>: View {
    @ObservedObject var appState: DictaFlowAppState
    @ViewBuilder var instructions: Instructions
    @State private var showsPicker = false
    @State private var showsAppsHelp = false
    private let catalog = WritingStyleApplicationCatalog()
    private var mode: RefinementMode { appState.refinementConfiguration.mode }
    private var applications: [WritingStyleApplication] {
        appState.refinementConfiguration.appStyleRules.filter { $0.value == mode }
            .map { catalog.application(bundleID: $0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        EmberPanel {
            EmberRow(title: "Style", detail: "Default for apps without a rule.") {
                Picker("Refinement writing style", selection: Binding(get: { mode }, set: { appState.updateRefinementMode($0) })) {
                    ForEach(RefinementMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 195)
            }
            EmberDivider()
            EmberRow(title: "Switch style by app", detail: "Match the app you dictate into when recording starts.") {
                Toggle("Switch style by app", isOn: Binding(
                    get: { appState.refinementConfiguration.perAppStylesEnabled },
                    set: { appState.updatePerAppStylesEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if appState.refinementConfiguration.perAppStylesEnabled {
                EmberDivider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text("Apps using \(mode.title)")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        Image(systemName: "info.circle")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                            .onHover { showsAppsHelp = $0 }
                            .overlay(alignment: .leading) {
                                if showsAppsHelp { appsHelpTooltip.offset(x: 16) }
                            }
                            .accessibilityLabel("About this app list")
                            .accessibilityHint("Switch the style above to see its apps. Unassigned apps use the selected style as the default. Rules apply to the next recording.")
                    }
                    .padding(.top, 15).padding(.bottom, 10).zIndex(10)
                    if applications.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            emptyState
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No apps yet.")
                                addButton
                            }
                        }
                        .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity).padding(.vertical, 22)
                    } else {
                        ForEach(applications) { application in
                            HStack(spacing: 10) {
                                Image(nsImage: application.icon).resizable().frame(width: 24, height: 24)
                                Text(application.name).font(.system(size: 12))
                                if application.url == nil {
                                    Text("Not installed").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer(minLength: 8)
                                Button { appState.removeWritingStyleRule(for: application.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 10))
                                }
                                .buttonStyle(EmberIconButtonStyle()).accessibilityLabel("Remove \(application.name)")
                            }
                            .padding(.vertical, 7).help(application.id)
                        }
                        Button { showsPicker = true } label: { Label("Add apps", systemImage: "plus.circle") }
                            .buttonStyle(EmberButtonStyle()).padding(.top, 10).padding(.bottom, 16)
                    }
                }.padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading)
            }
            instructions
        }
        .disabled(appState.refinementSettingsLocked)
        .sheet(isPresented: $showsPicker) { WritingStyleAppPicker(appState: appState, mode: mode) }
    }

    private var appsHelpTooltip: some View {
        Text("Switch the style above to see its apps. Unassigned apps use the selected style as the default. Rules apply to the next recording.")
            .font(.system(size: 11)).foregroundStyle(AppTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(width: 240, alignment: .leading)
            .background(AppTheme.glass, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border, lineWidth: 1) }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var emptyState: some View {
        HStack(spacing: 3) {
            Text("No apps yet.")
            addButton
            Text("using this style.")
        }
    }

    private var addButton: some View {
        Button { showsPicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                Text("Add apps").underline()
            }
        }
        .buttonStyle(.plain).accessibilityLabel("Add apps to \(mode.title)")
    }
}
