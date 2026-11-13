import SwiftUI

/// Plain-words setup state for one host card. It reports CLI detection
/// plus the configured server entry, and never claims a live connection.
enum AgentVoiceHostCardStatus: Equatable {
    case ready(hooksInstalled: Bool)
    case needsSetup
    case disabledInHost
    case notFound
    case manualOnly
    case checking

    var accessibilityDescription: String {
        switch self {
        case .ready(let hooksInstalled):
            hooksInstalled
                ? "MCP and voice hooks are configured."
                : "MCP is configured but voice hooks are missing."
        case .needsSetup:
            "Found on this Mac. DictaFlow entry not configured."
        case .disabledInHost:
            "DictaFlow entry is disabled in the host settings."
        case .notFound:
            "Not detected in common install locations."
        case .manualOnly:
            "Manual setup only, no installation detection."
        case .checking:
            "Found on this Mac, checking configuration."
        }
    }
}

/// Manual setup content shown under Manual configuration. One-click setup
/// performs the same registration automatically.
struct AgentVoiceHostAdvancedConfig {
    let snippet: String
    let hooksSnippet: String?
    let hooksNote: String?
}

/// One primary setup action, with documentation beside the host name.
/// Manual snippets keep their copy actions in their own headers.
struct AgentVoiceHostCard: View {
    let brand: AgentVoiceHostBrand
    let status: AgentVoiceHostCardStatus
    let hint: String
    let setupTitle: String
    let showSetupButton: Bool
    let canSetUp: Bool
    let isSettingUp: Bool
    let notice: String?
    let errorMessage: String?
    let copiedSetup: Bool
    let copiedHooks: Bool
    let advanced: AgentVoiceHostAdvancedConfig
    let onSetUp: () -> Void
    let onCopySetup: () -> Void
    let onCopyHooks: () -> Void
    @State private var showsManualConfiguration = false

    private var offersOneClickSetup: Bool { showSetupButton && canSetUp }

    private var guidance: String? {
        switch status {
        case .ready(let hooksInstalled):
            return hooksInstalled ? nil : "Update setup to add the missing voice hooks."
        case .needsSetup, .manualOnly:
            return hint
        case .checking:
            return nil
        case .disabledInHost:
            return "Enable DictaFlow in \(brand.displayName) settings."
        case .notFound:
            return canSetUp ? hint : "Install \(brand.displayName), then reopen this page."
        }
    }

    var body: some View {
        EmberPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AgentVoiceHostIcon(brand: brand, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(brand.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            if let url = brand.host.docsURL {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 13))
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).foregroundStyle(AppTheme.secondaryText)
                                .accessibilityLabel("\(brand.host.docsLabel), opens in browser")
                                .help("Open \(brand.host.docsLabel)")
                            }
                        }
                        if let vendor = brand.vendorName {
                            Text(vendor).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    headerAction
                }
                if let guidance {
                    Text(guidance).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.modelActive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Setup failed. \(errorMessage)")
                }
                if offersOneClickSetup { configurationButton }
                if showsManualConfiguration {
                    VStack(alignment: .leading, spacing: 14) {
                        codeBlock(title: "MCP server", text: advanced.snippet, copied: copiedSetup, onCopy: onCopySetup)
                        if let hooks = advanced.hooksSnippet {
                            if let note = advanced.hooksNote {
                                Text(note).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            codeBlock(title: "Voice hooks", text: hooks, copied: copiedHooks, onCopy: onCopyHooks)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .accessibilityIdentifier("agent-voice-host-card-\(brand.host.rawValue)")
    }

    private var configurationButton: some View {
        Button { showsManualConfiguration.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: showsManualConfiguration ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    .accessibilityHidden(true)
                Text("Manual configuration").font(.system(size: 12))
            }
            .frame(minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsManualConfiguration ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("agent-voice-manual-\(brand.host.rawValue)")
    }

    @ViewBuilder private var headerAction: some View {
        if offersOneClickSetup {
            Button(isSettingUp ? "Setting up…" : status == .checking ? "Checking…" : setupTitle, action: onSetUp)
                .buttonStyle(EmberButtonStyle(primary: true))
                .disabled(isSettingUp || status == .checking)
                .accessibilityLabel("\(setupTitle) Agent Voice for \(brand.displayName)")
                .accessibilityHint(status.accessibilityDescription)
                .accessibilityIdentifier("agent-voice-setup-\(brand.host.rawValue)")
        } else {
            Button(showsManualConfiguration ? "Hide setup" : "Show setup") { showsManualConfiguration.toggle() }
                .buttonStyle(EmberButtonStyle(primary: true))
                .accessibilityLabel("\(showsManualConfiguration ? "Hide" : "Show") setup for \(brand.displayName)")
                .accessibilityHint(status.accessibilityDescription)
        }
    }

    private func codeBlock(title: String, text: String, copied: Bool, onCopy: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                Button(action: onCopy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain).font(.system(size: 11))
                .foregroundStyle(copied ? AppTheme.modelActive : AppTheme.primaryText)
                .padding(4)
                .accessibilityLabel("Copy \(brand.displayName) \(title)")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            EmberDivider()
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: min(220, CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count) * 15 + 24))
        }
        .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border, lineWidth: 1) }
    }
}
