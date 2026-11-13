import SwiftUI

/// Friendly identity for an Agent Voice host app. Rendered everywhere a
/// host appears so setup cards, history rows, and overlay labels stay
/// consistent. Known hosts use their vendor logo from the asset catalog on
/// a fixed white tile; niche and unknown hosts fall back to an SF Symbol.
struct AgentVoiceHostBrand {
    let host: AgentVoiceHostAvailability.Host
    let displayName: String
    /// Vendor behind the host app, shown in session detail. Set only where
    /// the attribution is certain; niche and unknown hosts leave it nil.
    let vendorName: String?
    /// One-line purpose shown under the host name.
    let purpose: String
    /// Asset catalog logo, or nil for the SF Symbol fallback.
    let logoAsset: String?
    let systemImage: String

    static func brand(for host: AgentVoiceHostAvailability.Host) -> AgentVoiceHostBrand {
        switch host {
        case .codex:
            AgentVoiceHostBrand(
                host: host,
                displayName: "Codex",
                vendorName: "OpenAI",
                purpose: "Speak your Codex agent's replies aloud.",
                logoAsset: "provider-openai",
                systemImage: "chevron.left.forwardslash.chevron.right"
            )
        case .claudeCode:
            AgentVoiceHostBrand(
                host: host,
                displayName: "Claude Code",
                vendorName: "Anthropic",
                purpose: "Speak your Claude Code agent's replies aloud.",
                logoAsset: "provider-anthropic",
                systemImage: "bubble.left.and.bubble.right"
            )
        case .museCode:
            AgentVoiceHostBrand(
                host: host,
                displayName: "Muse Code",
                vendorName: "Meta",
                purpose: "Speak your Muse agent's replies aloud.",
                logoAsset: "provider-meta",
                systemImage: "command"
            )
        case .other:
            AgentVoiceHostBrand(
                host: host,
                displayName: "Other hosts",
                vendorName: nil,
                purpose: "Connect any MCP host with manual setup.",
                logoAsset: nil,
                systemImage: "app.dashed"
            )
        }
    }

    /// Maps a stored session host string to a brand. The MCP `--host` flag is
    /// stored verbatim ("codex", "claude", "muse", ...), so matching is loose:
    /// case-insensitive with separators ignored. Unknown hosts fall back to a
    /// placeholder glyph and keep the raw host name visible.
    static func brand(forHostName hostName: String) -> AgentVoiceHostBrand {
        let normalized = hostName.lowercased()
            .filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "codex":
            return brand(for: .codex)
        case "claude", "claudecode":
            return brand(for: .claudeCode)
        case "muse", "musecode":
            return brand(for: .museCode)
        case "opencode":
            return AgentVoiceHostBrand(
                host: .other,
                displayName: "OpenCode",
                vendorName: nil,
                purpose: "Speak your OpenCode agent's replies aloud.",
                logoAsset: nil,
                systemImage: "terminal"
            )
        case "pi", "piagent":
            return AgentVoiceHostBrand(
                host: .other,
                displayName: "Pi",
                vendorName: nil,
                purpose: "Speak your Pi agent's replies aloud.",
                logoAsset: nil,
                systemImage: "terminal"
            )
        default:
            let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentVoiceHostBrand(
                host: .other,
                displayName: trimmed.isEmpty ? "Unknown host" : trimmed,
                vendorName: nil,
                purpose: "Speak this agent's replies aloud.",
                logoAsset: nil,
                systemImage: "app.dashed"
            )
        }
    }
}

/// Host brand icon. Known hosts render their fixed-color vendor logo on
/// a white tile so it reads in both appearances; niche and unknown hosts
/// fall back to a monochrome SF Symbol tile.
struct AgentVoiceHostIcon: View {
    let brand: AgentVoiceHostBrand
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let asset = brand.logoAsset {
                Image(asset).resizable().scaledToFit().padding(size * 0.15)
            } else {
                Image(systemName: brand.systemImage)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
            }
        }
        .frame(width: size, height: size)
        .background(
            brand.logoAsset == nil ? AppTheme.controlFill : .white,
            in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        )
        .accessibilityHidden(true)
    }
}
