import Foundation

/// A scripted pair of fake sessions that runs through every state the bar can show.
/// Trigger it from the gear menu or with `curl -X POST localhost:47823/demo`.
@MainActor
enum Demo {
    static func play(on store: SessionStore) {
        let main = "demo-" + UUID().uuidString.prefix(8)
        let side = "demo-" + UUID().uuidString.prefix(8)
        let mainCwd = NSHomeDirectory() + "/Projects/claudebar"
        let sideCwd = NSHomeDirectory() + "/Projects/weather-api"
        var steps: [(TimeInterval, [String: Any])] = []

        func event(_ time: TimeInterval, _ name: String, _ session: String, _ extra: [String: Any] = [:]) {
            var payload: [String: Any] = [
                "hook_event_name": name,
                "session_id": session,
                "cwd": session == main ? mainCwd : sideCwd,
                "claudebar_demo": true,
            ]
            payload.merge(extra) { _, new in new }
            steps.append((time, payload))
        }
        func tool(_ start: TimeInterval, _ end: TimeInterval, _ session: String, _ id: String, _ name: String,
                  _ input: [String: Any], agent: String? = nil) {
            var fields: [String: Any] = ["tool_use_id": id, "tool_name": name, "tool_input": input]
            if let agent { fields["agent_id"] = agent }
            event(start, "PreToolUse", session, fields)
            event(end, "PostToolUse", session, fields)
        }
        func lines(_ count: Int, _ prefix: String) -> String {
            (1...count).map { "\(prefix) line \($0)" }.joined(separator: "\n")
        }

        event(0.0, "SessionStart", main, ["model": "claude-opus-5-5", "source": "startup"])
        event(0.2, "UserPromptSubmit", main, ["prompt": "make the notch bar feel alive — glow, sparks, the works"])
        event(1.0, "MessageDisplay", main, ["delta": "Let me look at how the notch view is put together first.\n"])
        tool(1.4, 2.2, main, "m1", "Read", ["file_path": mainCwd + "/Sources/NotchView.swift"])
        tool(2.5, 3.0, main, "m2", "Grep", ["pattern": "GlowOutline"])
        tool(3.3, 4.6, main, "m3", "Edit", ["file_path": mainCwd + "/Sources/NotchView.swift",
                                           "old_string": lines(4, "old"), "new_string": lines(38, "new")])

        event(3.8, "UserPromptSubmit", side, ["prompt": "fix the flaky retry in the fetcher"])
        tool(4.4, 5.2, side, "s1", "Read", ["file_path": sideCwd + "/src/fetcher.ts"])
        tool(5.6, 6.5, side, "s2", "Edit", ["file_path": sideCwd + "/src/fetcher.ts",
                                           "old_string": lines(9, "retry"), "new_string": lines(14, "backoff")])
        event(8.6, "Stop", side)

        tool(5.0, 7.8, main, "m4", "Bash", ["command": "swift build -c release"])
        event(8.1, "PreToolUse", main, ["tool_use_id": "m5", "tool_name": "Bash", "tool_input": ["command": "rm -rf .build/cache"]])
        event(8.3, "PermissionRequest", main, ["tool_name": "Bash", "tool_input": ["command": "rm -rf .build/cache"]])
        event(11.4, "PostToolUse", main, ["tool_use_id": "m5", "tool_name": "Bash", "tool_input": ["command": "rm -rf .build/cache"]])

        event(11.8, "SubagentStart", main, ["agent_id": "a1", "agent_type": "Explore"])
        event(11.9, "PreToolUse", main, ["tool_use_id": "m6", "tool_name": "Agent", "tool_input": ["description": "Audit animation timings"]])
        tool(12.3, 13.0, main, "a1-1", "Grep", ["pattern": "spring\\(response"], agent: "a1")
        tool(13.1, 13.7, main, "a1-2", "Read", ["file_path": mainCwd + "/Sources/Components.swift"], agent: "a1")
        event(13.9, "SubagentStop", main, ["agent_id": "a1", "agent_type": "Explore"])
        event(14.0, "PostToolUse", main, ["tool_use_id": "m6", "tool_name": "Agent", "tool_input": ["description": "Audit animation timings"]])
        tool(14.3, 15.2, main, "m7", "Write", ["file_path": mainCwd + "/Sources/Sparkle.swift", "content": lines(52, "spark")])
        event(15.5, "MessageDisplay", main, ["delta": "Done — the notch now glows while I work and bursts when I finish.\n"])
        event(16.2, "Stop", main)

        for (time, payload) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                MainActor.assumeIsolated {
                    store.handle(HookEnvelope(payload: payload))
                }
            }
        }
    }
}
