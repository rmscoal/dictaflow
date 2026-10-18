import SwiftUI
import UniformTypeIdentifiers

struct WritingStyleAppPicker: View {
    @ObservedObject var appState: DictaFlowAppState
    let mode: RefinementMode
    var catalog: any WritingStyleApplicationCatalogProtocol = WritingStyleApplicationCatalog()
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var running: [WritingStyleApplication] = []
    @State private var suggested: [WritingStyleApplication] = []
    @State private var browsed: [WritingStyleApplication] = []
    @State private var confirmsMove = false
    @State private var browseError: String?

    private var applications: [WritingStyleApplication] { running + suggested + browsed }
    private var movers: [WritingStyleApplication] {
        applications.filter {
            selected.contains($0.id) && appState.refinementConfiguration.appStyleRules[$0.id] != nil
                && appState.refinementConfiguration.appStyleRules[$0.id] != mode
        }
    }
    private func countLabel(_ count: Int) -> String { "\(count) \(count == 1 ? "app" : "apps")" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add apps").font(.system(size: 21, weight: .medium))
                    Text("Apps join the style selected in the window.").font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(EmberIconButtonStyle()).accessibilityLabel("Close app picker")
            }.padding(22)
            EmberDivider()
            TextField("Search applications", text: $query).textFieldStyle(.roundedBorder).padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    group("Currently open", applications: running)
                    group("Suggested", applications: suggested)
                    group("From disk", applications: browsed)
                    if !applications.contains(where: matches) {
                        Text("No applications match this search.").font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    }
                    Button("Browse applications…") { browse() }.buttonStyle(EmberButtonStyle())
                    if let browseError { Text(browseError).font(.system(size: 12)).foregroundStyle(AppTheme.errorText) }
                }.padding(.horizontal, 22).padding(.bottom, 20)
            }
            EmberDivider()
            HStack(spacing: 12) {
                Text("Adds to \(mode.title). Moving an app from another style asks for confirmation.")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.buttonStyle(EmberButtonStyle()).keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Add" : "Add \(countLabel(selected.count))") {
                    if movers.isEmpty { apply() } else { confirmsMove = true }
                }.buttonStyle(EmberButtonStyle(primary: true)).disabled(selected.isEmpty || appState.refinementSettingsLocked)
            }.padding(20)
        }
        .frame(width: 580, height: 560)
        .foregroundStyle(AppTheme.primaryText).background(AppTheme.tileFill).tint(AppTheme.accent)
        .onAppear {
            running = catalog.runningApplications()
            let ids = Set(running.map(\.id))
            suggested = catalog.suggestedApplications().filter { !ids.contains($0.id) }
        }
        .sheet(isPresented: $confirmsMove) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Move \(countLabel(movers.count)) to \(mode.title)?").font(.system(size: 19, weight: .medium))
                Text("Each app can only use one writing style.").font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(movers) { application in
                            HStack(alignment: .top, spacing: 10) {
                                Image(nsImage: application.icon).resizable().frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(application.name).font(.system(size: 12, weight: .medium))
                                    Text("\(appState.refinementConfiguration.appStyleRules[application.id]?.title ?? "") → \(mode.title)")
                                        .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 230)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmsMove = false }.buttonStyle(EmberButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Move \(countLabel(movers.count))") { apply() }
                        .buttonStyle(EmberButtonStyle(primary: true)).disabled(appState.refinementSettingsLocked)
                }
            }.padding(22).frame(width: 425).foregroundStyle(AppTheme.primaryText).background(AppTheme.tileFill)
        }
    }

    private func matches(_ application: WritingStyleApplication) -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty || application.name.localizedCaseInsensitiveContains(search) || application.id.localizedCaseInsensitiveContains(search)
    }

    @ViewBuilder private func group(_ title: String, applications: [WritingStyleApplication]) -> some View {
        let filtered = applications.filter(matches)
        if !filtered.isEmpty {
            Text(title).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            ForEach(filtered) { application in
                let assigned = appState.refinementConfiguration.appStyleRules[application.id]
                HStack(alignment: .center, spacing: 10) {
                    Toggle("Select \(application.name)", isOn: Binding(get: { selected.contains(application.id) }, set: { checked in
                        if checked { selected.insert(application.id) } else { selected.remove(application.id) }
                    }))
                    .labelsHidden().toggleStyle(.checkbox)
                    .disabled(assigned == mode)
                    HStack(spacing: 10) {
                        Image(nsImage: application.icon).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(application.name).font(.system(size: 12))
                            Text(application.id).font(.system(size: 10)).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard assigned != mode else { return }
                        if selected.contains(application.id) { selected.remove(application.id) } else { selected.insert(application.id) }
                    }
                    Spacer(minLength: 8)
                    if let assigned {
                        Text(assigned == mode ? "Uses this style" : assigned.title)
                            .font(.system(size: 10)).foregroundStyle(AppTheme.secondaryText).multilineTextAlignment(.trailing)
                    }
                }.padding(.vertical, 4)
            }
        }
    }

    private func apply() {
        guard !appState.refinementSettingsLocked else { return }
        appState.assignWritingStyle(mode, to: selected)
        confirmsMove = false
        dismiss()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        browseError = nil
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
                browseError = "Choose an application with a bundle identifier other than DictaFlow."
                continue
            }
            if !applications.contains(where: { $0.id == id }) {
                browsed.append(WritingStyleApplication(id: id, name: FileManager.default.displayName(atPath: url.path), url: url))
            }
            if appState.refinementConfiguration.appStyleRules[id] != mode { selected.insert(id) }
        }
    }
}
