import Foundation

/// Main-agent-only guard for PreToolUse command hooks (Claude Code, Muse Code).
///
/// The host runs the bundled helper once per tool call with `--hook-event
/// PreToolUse --host <claude|muse>`, the event payload on stdin, and a
/// host-controlled environment. This type decides the hook answer purely from
/// host-supplied identity, never from model-supplied tool arguments:
/// - Claude Code: `agent_id` in the stdin payload identifies a subagent,
///   teammate, or other non-root context. It is absent in the main session.
///   `agent_type` alone is not proof of a child (`--agent` sets it at root).
/// - Muse Code: `MUSE_SESSION_ID` names the top-level chat and
///   `MUSE_THREAD_ID` names the chat or subagent the hook fires for; they are
///   equal at top level. The host replaces any other values.
///
/// A denied call returns one JSON object denying the tool; an allowed call
/// returns nil and the helper prints nothing. Both exit 0 so the host always
/// continues. Malformed stdin fails open (allows), because only the host can
/// produce it and blocking on a host bug would silence the main agent.
/// Missing Muse identity fails closed with an actionable reason: unlike an
/// absent Claude `agent_id`, it is not a specified main-session signal, so it
/// must not silently pass as root.
public enum HookGuard {
    /// Returns the stdout answer for one hook invocation, or nil to allow
    /// silently. `event` must be the firing event (echoed back as
    /// `hookEventName`, which both hosts require to match).
    public static func response(event: String, host: String, stdin: Data,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        switch host {
        case "claude":
            guard stdinAgentID(stdin) != nil else { return nil }
            return deny(event: event, reason: "Omdo voice is main-agent only, so this child call was not sent. Finish the written answer normally.")
        case "muse":
            // A future Muse payload may also carry agent_id on this event;
            // the main session never has one under either host's spec, so a
            // non-empty value is always a child, whatever the environment says.
            if stdinAgentID(stdin) != nil {
                return deny(event: event, reason: "Omdo voice is main-agent only, so this child call was not sent. Finish the written answer normally.")
            }
            guard let session = environment["MUSE_SESSION_ID"], !session.isEmpty,
                  let thread = environment["MUSE_THREAD_ID"], !thread.isEmpty else {
                return deny(event: event, reason: "Omdo could not verify the calling agent because the host session identity is missing. Update Muse Code and start a new session; the written answer is unaffected.")
            }
            guard session != thread else { return nil }
            return deny(event: event, reason: "Omdo voice is main-agent only, so this child call was not sent. Finish the written answer normally.")
        default:
            return nil
        }
    }

    /// Host-supplied child identity from a hook payload, or nil for the main
    /// session and for malformed input (which fails open). Only a non-empty
    /// string counts; `agent_type` is deliberately ignored.
    private static func stdinAgentID(_ stdin: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let id = json["agent_id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private static func deny(event: String, reason: String) -> String? {
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": event,
                                                             "permissionDecision": "deny",
                                                             "permissionDecisionReason": reason]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
