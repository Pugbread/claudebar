import Foundation

/// One Claude Code hook event, plus the metadata the hook script adds as headers.
struct HookEnvelope {
    let payload: [String: Any]
    let agent: Agent
    let hostBundleID: String?
    let termProgram: String?
    let agentPID: pid_t?
    let receivedAt: Date

    init?(body: Data, headers: [String: String]) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let agent = headers["x-claudebar-agent"].flatMap(Agent.init(rawValue:)) ?? .claude
        // CLAUDE_PID is only trustworthy for Claude; Codex's process is found by walking up.
        let explicitPID = agent == .claude ? headers["x-claudebar-claude-pid"].flatMap { pid_t($0) } : nil
        let parentPID = headers["x-claudebar-ppid"].flatMap { pid_t($0) }
        self.init(
            payload: object,
            agent: agent,
            hostBundleID: headers["x-claudebar-bundle"],
            termProgram: headers["x-claudebar-term"],
            agentPID: explicitPID ?? parentPID.flatMap { ProcessLookup.agentProcess(named: agent.processName, startingAt: $0) }
        )
    }

    init(payload: [String: Any], agent: Agent = .claude, hostBundleID: String? = nil, termProgram: String? = nil,
         agentPID: pid_t? = nil) {
        self.payload = payload
        self.agent = agent
        self.hostBundleID = hostBundleID?.nilIfEmpty
        self.termProgram = termProgram?.nilIfEmpty
        self.agentPID = agentPID
        self.receivedAt = Date()
    }

    var event: String { string("hook_event_name") ?? "" }
    var sessionID: String { string("session_id") ?? "unknown" }
    /// Set when the hook fired inside a subagent (absent on the main thread).
    var agentID: String? { string("agent_id") }
    var isDemo: Bool { payload["claudebar_demo"] as? Bool ?? false }

    func string(_ key: String) -> String? { (payload[key] as? String)?.nilIfEmpty }
    func int(_ key: String) -> Int? { (payload[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool? { payload[key] as? Bool }
    func dict(_ key: String) -> [String: Any] {
        if let value = payload[key] as? [String: Any] { return value }
        // Codex sends freeform tools' input (like apply_patch) as a bare string.
        if let text = payload[key] as? String { return ["input": text] }
        return [:]
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
