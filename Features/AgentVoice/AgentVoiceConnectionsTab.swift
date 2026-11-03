import AppKit
import SwiftUI

/// First Agent Voice tab. Local enable/disable state plus manual per-host
/// setup. Nothing here configures a host automatically, and nothing
/// reports a live host connection: detection only reflects whether a host
/// command exists in the searched install locations.
struct AgentVoiceConnectionsTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator
    @State private var selectedHost: AgentVoiceHostAvailability.Host = .codex
    @State private var copiedConfirmation: String?
    @State private var hostAvailability: [AgentVoiceHostAvailability.Host: AgentVoiceHostAvailability.Result] = [:]

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
                        Button("Copy setup") { copy(setupSnippet(for: selectedHost), label: selectedHost.name) }
                            .buttonStyle(EmberButtonStyle(primary: true))
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
        .onChange(of: voice.connectionCommand) { _, _ in copiedConfirmation = nil }
        .onAppear {
            for host in AgentVoiceHostAvailability.Host.allCases where host != .other {
                hostAvailability[host] = AgentVoiceHostAvailability.check(host)
            }
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
            } else if hostAvailability[host]?.isDetected == true {
                Label("Detected", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.modelActive)
                    .accessibilityLabel("\(host.name) detected on this Mac. Not connected.")
            } else {
                Label("Not detected", systemImage: "minus.circle")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    .accessibilityLabel("\(host.name) not detected in common install locations")
            }
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
                "Open ~/.codex/config.toml. Update the existing [mcp_servers.dictaflow] entry if present; add the block below only when absent. Preserve all other settings.",
                "Start a new Codex session so it picks up the server.",
            ]
        case .claudeCode:
            return [
                "Keep Enable Agent Voice turned on above.",
                "If dictaflow is already registered, update that server using the Claude Code documentation. Otherwise run the copied command once in Terminal to register it.",
                "Start a new Claude Code session so it picks up the server.",
            ]
        case .museCode:
            return [
                "Keep Enable Agent Voice turned on above.",
                "Open ~/.config/muse/settings.json (create it if missing) and merge the dictaflow entry below, keeping \"schema_version\": 1.",
                "Start a new Muse session so it loads the server at startup.",
            ]
        case .other:
            return [
                "Keep Enable Agent Voice turned on above.",
                "Register the copied command as a stdio MCP server named dictaflow in your host.",
                "In DictaFlow, play each prepared response yourself.",
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
        ("on_stop", "Observes Stop. It never starts playback by itself."),
        ("on_interrupt", "Cancels speech for an interrupted input. It does not cancel the agent."),
        ("get_speech_status", "Reads an input's current speech state."),
    ]
}
