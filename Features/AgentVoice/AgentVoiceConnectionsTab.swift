import AppKit
import AgentVoice
import SwiftUI

/// First Agent Voice tab. Local enable/disable state plus per-host setup
/// with a one-click Set up button. Status never claims a live host
/// connection: it reports whether the host CLI was found and whether its
/// DictaFlow server entry is configured. The connection itself happens
/// inside a new host session.
struct AgentVoiceConnectionsTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator
    @State private var selectedHost: AgentVoiceHostAvailability.Host = .codex
    @State private var copiedConfirmation: String?
    @State private var hostAvailability: [AgentVoiceHostAvailability.Host: AgentVoiceHostAvailability.Result] = [:]
    @State private var hostState: [AgentVoiceHostAvailability.Host: AgentVoiceHostInstaller.HostState] = [:]
    @State private var isSettingUp = false
    @State private var setupNotice: String?
    @State private var setupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberPanel {
                EmberRow(title: "Enable Agent Voice") {
                    Toggle("Enable Agent Voice", isOn: Binding(
                        get: { voice.isEnabled },
                        set: { voice.setEnabled($0) }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("Enable Agent Voice")
                }
                EmberRow(title: "Playback") {
                    Picker("Playback", selection: Binding(
                        get: { voice.admissionPolicy },
                        set: { voice.setAdmissionPolicy($0) }
                    )) {
                        Text("Speak automatically").tag(VoiceAdmissionPolicy.automatic)
                        Text("Show Play control").tag(VoiceAdmissionPolicy.manualOnly)
                    }
                    .labelsHidden().frame(width: 190)
                    .accessibilityLabel("Agent Voice playback")
                }
            }
            .padding(.bottom, 18)
            if let error = voice.activeError {
                EmberErrorBanner(title: "Agent Voice needs attention", message: error.message)
                    .padding(.bottom, 18)
                    .accessibilityLabel("Agent Voice error. \(error.message)")
            }

            EmberSectionHeading(title: "Host setup")
            EmberPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Host", selection: $selectedHost) {
                        ForEach(AgentVoiceHostAvailability.Host.allCases) { host in
                            Text(host.name).tag(host)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityLabel("Host")
                    HStack(spacing: 10) {
                        Text(selectedHost.name).font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 8)
                        availabilityLabel(host: selectedHost)
                    }
                    steps(for: selectedHost)
                    HStack(spacing: 8) {
                        if selectedHost != .other {
                            Button(isSettingUp ? "Setting up…" : setupButtonTitle(for: selectedHost)) {
                                setUp(selectedHost)
                            }
                            .buttonStyle(EmberButtonStyle(primary: true))
                            .disabled(isSettingUp || !canSetUp(selectedHost))
                            .accessibilityLabel("Set up \(selectedHost.name)")
                        }
                        Button("Copy setup") { copy(setupSnippet(for: selectedHost), label: selectedHost.name) }
                            .buttonStyle(EmberButtonStyle(primary: selectedHost == .other))
                            .accessibilityLabel("Copy \(selectedHost.name) setup")
                        if let url = selectedHost.docsURL {
                            Link(selectedHost.docsLabel, destination: url)
                                .font(.system(size: 12))
                                .accessibilityLabel("\(selectedHost.docsLabel), opens in browser")
                        }
                        Spacer(minLength: 0)
                        if copiedConfirmation == selectedHost.name {
                            Label("Copied", systemImage: "checkmark")
                                .font(.system(size: 12)).foregroundStyle(AppTheme.modelActive)
                                .accessibilityLabel("\(selectedHost.name) setup copied")
                        }
                    }
                    if let setupNotice {
                        Label(setupNotice, systemImage: "checkmark.circle")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.modelActive)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(setupNotice)
                    }
                    if let setupError {
                        Label(setupError, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Setup failed. \(setupError)")
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Self.executablePath)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(setupSnippet(for: selectedHost))
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                            if let hooks = try? AgentVoiceHostSetup.hooksSnippet(for: selectedHost) {
                                Text(selectedHost == .codex
                                     ? "Merge into ~/.codex/hooks.json, then review the hooks in Codex with /hooks."
                                     : "Merge the hooks into ~/.claude/settings.json.")
                                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                                Text(hooks)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                                Button("Copy hooks") { copy(hooks, label: "hooks") }
                                    .buttonStyle(EmberButtonStyle())
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Advanced config").font(.system(size: 12))
                    }
                    .disclosureGroupStyle(EmberDisclosureGroupStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .padding(.bottom, 26)

            EmberSectionHeading(title: "Available tools")
            EmberPanel {
                toolsList
            }
        }
        .onChange(of: voice.connectionCommand) { _, _ in
            copiedConfirmation = nil
            setupNotice = nil
            setupError = nil
            refreshStatus()
        }
        .onChange(of: selectedHost) { _, _ in
            setupNotice = nil
            setupError = nil
        }
        .onAppear {
            for host in AgentVoiceHostAvailability.Host.allCases where host != .other {
                hostAvailability[host] = AgentVoiceHostAvailability.check(host)
            }
            refreshStatus()
        }
    }

    // MARK: - Host setup

    private func availabilityLabel(host: AgentVoiceHostAvailability.Host) -> some View {
        Group {
            if host == .other {
                Text("Manual setup")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Manual setup only, no installation detection")
            } else if let state = hostState[host] {
                switch state.status {
                case .configured:
                    Label(state.hooksConfigured ? "MCP + hooks installed" : "MCP configured", systemImage: "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.modelActive)
                        .accessibilityLabel("\(host.name). \(state.hooksConfigured ? "MCP and hook definitions installed. Review them in the host." : "MCP configured. Lifecycle hooks are not verified.") Start a new session.")
                case .foundNotConfigured:
                    Label("Found · Not configured", systemImage: "circle")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        .accessibilityLabel("\(host.name) found on this Mac, DictaFlow entry not configured.")
                case .notFound, .manualOnly:
                    Label("Not found", systemImage: "minus.circle")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        .accessibilityLabel("\(host.name) not detected in common install locations")
                }
            } else if hostAvailability[host]?.isDetected == true {
                Label("Found · Checking…", systemImage: "circle")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    .accessibilityLabel("\(host.name) found on this Mac, checking configuration.")
            } else {
                Label("Not found", systemImage: "minus.circle")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    .accessibilityLabel("\(host.name) not detected in common install locations")
            }
        }
    }

    private func setupButtonTitle(for host: AgentVoiceHostAvailability.Host) -> String {
        if hostState[host]?.status == .configured { return "Update \(host.name)" }
        return "Set up \(host.name)"
    }

    private func canSetUp(_ host: AgentVoiceHostAvailability.Host) -> Bool {
        if host == .museCode { return true }
        return hostAvailability[host]?.isDetected == true
    }

    private func refreshStatus() {
        let executable = Self.executablePath
        let appID = voice.appID
        let installationID = voice.installationID
        Task {
            var next: [AgentVoiceHostAvailability.Host: AgentVoiceHostInstaller.HostState] = [:]
            for host in AgentVoiceHostAvailability.Host.allCases where host != .other {
                next[host] = await AgentVoiceHostInstaller.refreshState(
                    host: host, executable: executable,
                    appID: appID, installationID: installationID)
            }
            let checked = next
            await MainActor.run {
                hostState = checked
                for host in AgentVoiceHostAvailability.Host.allCases where host != .other {
                    hostAvailability[host] = AgentVoiceHostAvailability.check(host)
                }
            }
        }
    }

    private func setUp(_ host: AgentVoiceHostAvailability.Host) {
        let executable = Self.executablePath
        let appID = voice.appID
        let installationID = voice.installationID
        let agentVoiceEnabled = voice.isEnabled
        isSettingUp = true
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
                isSettingUp = false
            }
            refreshStatus()
        }
    }

    @ViewBuilder
    private func steps(for host: AgentVoiceHostAvailability.Host) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.manualSteps(for: host), id: \.self) { step in
                HStack(alignment: .top, spacing: 8) {
                    Text("·").foregroundStyle(AppTheme.secondaryText)
                    Text(step).font(.system(size: 12)).foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Snippets

    private static var executablePath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dictaflow-mcp").path
    }

    private func setupSnippet(for host: AgentVoiceHostAvailability.Host) -> String {
        do {
            return try AgentVoiceHostSetup.snippet(for: host, executable: Self.executablePath,
                                                  appID: voice.appID, installationID: voice.installationID)
        } catch { return "Could not create the setup snippet. Try reopening Agent Voice." }
    }

    private static func manualSteps(for host: AgentVoiceHostAvailability.Host) -> [String] {
        switch host {
        case .codex:
            return [
                "Keep Enable Agent Voice turned on above.",
                "Set up registers DictaFlow and installs prompt, Stop, and interruption hooks in your user configuration, preserving other settings.",
                "Open /hooks in Codex and review and trust the DictaFlow hooks. Start a new session to use Agent Voice.",
            ]
        case .claudeCode:
            return [
                "Keep Enable Agent Voice turned on above.",
                "Set up registers DictaFlow and installs prompt and Stop hooks in your user configuration, preserving other settings.",
                "Start a new Claude Code session so it picks up the server.",
                "Use DictaFlow's Stop or dictation control to interrupt speech. Claude's own interruption event is not connected.",
            ]
        case .museCode:
            return [
                "Keep Enable Agent Voice turned on above.",
                "Press Set up Muse Code. It merges the dictaflow entry into ~/.config/muse/settings.json and keeps your other settings. Advanced config below holds the manual equivalent.",
                "Start a new Muse session so it loads the server at startup.",
                "Native lifecycle hooks are not configured for Muse. Use manual playback until your host integration supplies them.",
            ]
        case .other:
            return [
                "Keep Enable Agent Voice turned on above.",
                "Register the copied command as a stdio MCP server named dictaflow in your host.",
                "Connect your host's prompt, completion, and interruption events. Hosts without lifecycle integration can use manual playback.",
            ]
        }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedConfirmation = label
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
