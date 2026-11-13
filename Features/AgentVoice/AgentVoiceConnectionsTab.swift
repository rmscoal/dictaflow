import AppKit
import AgentVoice
import SwiftUI

/// General controls, speech model, and host setup. Host status describes
/// installed configuration, not a live MCP connection.
struct AgentVoiceConnectionsTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator
    /// Copies setup snippets. Wired to the shared pasteboard writer so
    /// copied text is marked transient and concealed.
    var onCopy: ((String) -> Void)?
    @State private var copiedConfirmation: String?
    @State private var selectedHost: AgentVoiceHostAvailability.Host?
    @State private var hostAvailability: [AgentVoiceHostAvailability.Host: AgentVoiceHostAvailability.Result] = [:]
    @State private var hostState: [AgentVoiceHostAvailability.Host: AgentVoiceHostInstaller.HostState] = [:]
    @State private var refreshGeneration = UUID()
    @State private var settingUpHost: AgentVoiceHostAvailability.Host?
    @State private var setupHost: AgentVoiceHostAvailability.Host?
    @State private var setupNotice: String?
    @State private var setupError: String?

    private typealias Host = AgentVoiceHostAvailability.Host

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberPanel {
                HStack {
                    Text("Enable Agent Voice").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 12)
                    Toggle("Enable Agent Voice", isOn: Binding(
                        get: { voice.isEnabled },
                        set: { voice.setEnabled($0) }
                    ))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("Enable Agent Voice")
                }
                .padding(18)
                EmberDivider()
                HStack(spacing: 14) {
                    Text("Playback").font(.system(size: 13))
                    Spacer(minLength: 12)
                    Picker("Playback", selection: Binding(
                        get: { voice.admissionPolicy },
                        set: { voice.setAdmissionPolicy($0) }
                    )) {
                        Text("Speak automatically").tag(VoiceAdmissionPolicy.automatic)
                        Text("Play on request").tag(VoiceAdmissionPolicy.manualOnly)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Agent Voice playback")
                }
                .padding(18)
            }
            .padding(.bottom, 18)
            if let error = voice.activeError, error.scope != .models {
                EmberErrorBanner(title: "Agent Voice needs attention", message: error.message)
                    .padding(.bottom, 18)
                    .accessibilityLabel("Agent Voice error. \(error.message)")
            }

            AgentVoiceModelsTab(voice: voice)
                .padding(.bottom, 22)

            EmberSectionHeading(title: "Connections")
            hostTabBar
            hostCard(for: effectiveHost)
                .padding(.bottom, 12)
            DisclosureGroup("Available MCP tools") { toolsList.padding(.top, 8) }
                .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                .disclosureGroupStyle(EmberDisclosureGroupStyle())
        }
        .onChange(of: voice.connectionCommand) { _, _ in
            copiedConfirmation = nil
            setupHost = nil
            setupNotice = nil
            setupError = nil
            refreshStatus()
        }
        .onAppear {
            for host in Host.allCases where host != .other {
                hostAvailability[host] = AgentVoiceHostAvailability.check(host)
            }
            refreshStatus()
        }
    }

    // MARK: - Host cards

    /// Host tabs in fixed order. One host card shows at a time.
    private var tabHosts: [Host] { [.codex, .museCode, .claudeCode, .other] }

    private var effectiveHost: Host { selectedHost ?? recommendedHost }

    private var hostTabBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                ForEach(tabHosts) { host in
                    Button { selectedHost = host } label: {
                        HStack(spacing: 7) {
                            AgentVoiceHostIcon(brand: .brand(for: host), size: 18)
                            Text(host == .other ? "Other" : host.name).lineLimit(1)
                        }
                        .font(.system(size: 12))
                        .frame(minWidth: 82).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(effectiveHost == host ? AppTheme.tileFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent-voice-host-\(host.rawValue)")
                    .accessibilityAddTraits(effectiveHost == host ? .isSelected : [])
                }
            }
            .padding(3).background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border, lineWidth: 1) }
            .padding(.bottom, 12)
            .accessibilityElement(children: .contain).accessibilityLabel("Host setup")
            Picker("Host", selection: Binding(get: { effectiveHost }, set: { selectedHost = $0 })) {
                ForEach(tabHosts) { host in Text(host == .other ? "Other" : host.name).tag(host) }
            }
            .labelsHidden().padding(.bottom, 12)
            .accessibilityLabel("Host setup")
        }
    }

    /// First CLI-detected host, else the first host that supports one-click
    /// setup. Muse Code needs no detected CLI, so this always resolves.
    private var recommendedHost: Host {
        let installable: [Host] = [.codex, .claudeCode, .museCode]
        return installable.first { hostAvailability[$0]?.isDetected == true }
            ?? installable.first { canSetUp($0) }
            ?? .museCode
    }

    private func hostCard(for host: Host) -> some View {
        let status = cardStatus(for: host)
        let hooksSnippet = try? AgentVoiceHostSetup.hooksSnippet(for: host)
        return AgentVoiceHostCard(
            brand: AgentVoiceHostBrand.brand(for: host),
            status: status,
            hint: Self.hint(for: host),
            setupTitle: setupButtonTitle(for: host),
            showSetupButton: host != .other,
            canSetUp: canSetUp(host),
            isSettingUp: settingUpHost == host,
            notice: setupHost == host ? setupNotice : nil,
            errorMessage: setupHost == host ? setupError : nil,
            copiedSetup: copiedConfirmation == Self.setupCopyKey(host),
            copiedHooks: copiedConfirmation == Self.hooksCopyKey(host),
            advanced: AgentVoiceHostAdvancedConfig(
                snippet: setupSnippet(for: host),
                hooksSnippet: hooksSnippet,
                hooksNote: Self.hooksNote(for: host, hasHooks: hooksSnippet != nil)
            ),
            onSetUp: { setUp(host) },
            onCopySetup: { copy(setupSnippet(for: host), key: Self.setupCopyKey(host)) },
            onCopyHooks: {
                if let hooks = try? AgentVoiceHostSetup.hooksSnippet(for: host) {
                    copy(hooks, key: Self.hooksCopyKey(host))
                }
            }
        )
    }

    private func cardStatus(for host: Host) -> AgentVoiceHostCardStatus {
        if host == .other { return .manualOnly }
        if let state = hostState[host] {
            switch state.status {
            case .configured:
                return .ready(hooksInstalled: state.hooksConfigured)
            case .disabled:
                return .disabledInHost
            case .foundNotConfigured:
                return .needsSetup
            case .notFound, .manualOnly:
                return .notFound
            }
        }
        if hostAvailability[host]?.isDetected == true { return .checking }
        return .notFound
    }

    private func setupButtonTitle(for host: Host) -> String {
        if hostState[host]?.status == .configured { return "Update" }
        return "Set up"
    }

    private func canSetUp(_ host: Host) -> Bool {
        if host == .museCode { return true }
        return hostAvailability[host]?.isDetected == true
    }

    private func refreshStatus() {
        let generation = UUID()
        refreshGeneration = generation
        let executable = Self.executablePath
        let appID = voice.appID
        let installationID = voice.installationID
        Task {
            var next: [Host: AgentVoiceHostInstaller.HostState] = [:]
            for host in Host.allCases where host != .other {
                next[host] = await AgentVoiceHostInstaller.refreshState(
                    host: host, executable: executable,
                    appID: appID, installationID: installationID)
            }
            let checked = next
            await MainActor.run {
                guard refreshGeneration == generation else { return }
                hostState = checked
                for host in Host.allCases where host != .other {
                    hostAvailability[host] = AgentVoiceHostAvailability.check(host)
                }
            }
        }
    }

    private func setUp(_ host: Host) {
        let executable = Self.executablePath
        let appID = voice.appID
        let installationID = voice.installationID
        let agentVoiceEnabled = voice.isEnabled
        refreshGeneration = UUID()
        settingUpHost = host
        setupHost = host
        setupNotice = nil
        setupError = nil
        Task {
            var notice: String?
            var failure: String?
            do {
                notice = try await AgentVoiceHostInstaller.setUp(
                    host: host, executable: executable,
                    appID: appID, installationID: installationID,
                    agentVoiceEnabled: agentVoiceEnabled)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await MainActor.run {
                setupNotice = notice
                setupError = failure
                settingUpHost = nil
            }
            refreshStatus()
        }
    }

    // MARK: - Snippets

    private static var executablePath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dictaflow-mcp").path
    }

    private func setupSnippet(for host: Host) -> String {
        do {
            return try AgentVoiceHostSetup.snippet(for: host, executable: Self.executablePath,
                                                  appID: voice.appID, installationID: voice.installationID)
        } catch { return "Could not create the setup snippet. Try reopening Agent Voice." }
    }

    private static func hint(for host: Host) -> String {
        switch host {
        case .codex:
            return "Adds DictaFlow and its voice hooks to Codex."
        case .claudeCode:
            return "Adds DictaFlow and its voice hooks to Claude Code."
        case .museCode:
            return "Adds DictaFlow to your Muse settings."
        case .other:
            return "Copy the command and register it as a stdio server named dictaflow."
        }
    }

    private static func hooksNote(for host: Host, hasHooks: Bool) -> String? {
        guard hasHooks else { return nil }
        if host == .codex {
            return "Merge into \(AgentVoiceHostInstaller.codexHooksURL().path), then review the hooks in Codex with /hooks."
        }
        return "With Claude Code 2.1.118 or later, merge the hooks into ~/.claude/settings.json."
    }

    private static func setupCopyKey(_ host: Host) -> String { "setup-\(host.rawValue)" }

    private static func hooksCopyKey(_ host: Host) -> String { "hooks-\(host.rawValue)" }

    private func copy(_ text: String, key: String) {
        if let onCopy {
            onCopy(text)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        copiedConfirmation = key
    }

    // MARK: - Tools list

    private var toolsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.tools.enumerated()), id: \.offset) { index, tool in
                VStack(alignment: .leading, spacing: 5) {
                    Text(tool.name).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    Text(tool.blurb).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(tool.name). \(tool.blurb)")
                if index < Self.tools.count - 1 { EmberDivider() }
            }
        }
    }

    private static let tools: [(name: String, blurb: String)] = [
        ("on_user_prompt_submit", "Notices a new prompt and returns an input identity with spoken-response instructions."),
        ("prepare_spoken_response", "Prepares a spoken response before the written answer. It never plays audio."),
        ("on_stop", "Makes the current response eligible for automatic speech, following your playback setting."),
        ("on_interrupt", "Cancels speech for an interrupted input. It does not cancel the agent."),
        ("get_speech_status", "Reads an input's current speech state."),
    ]
}
