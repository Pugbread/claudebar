import SwiftUI

enum ToolKind: String {
    case edit, read, search, shell, web, agent, mcp, plan, ask, other

    init(tool: String) {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": self = .edit
        case "Read", "NotebookRead", "view_image": self = .read
        case "Grep", "Glob", "LS", "LSP", "ToolSearch": self = .search
        case "Bash", "BashOutput", "KillShell", "KillBash", "Monitor", "TaskOutput", "TaskStop",
             "exec_command", "exec", "shell", "local_shell", "write_stdin": self = .shell
        case "WebFetch", "WebSearch", "web_search": self = .web
        case "Task", "Agent", "SendMessage", "Workflow", "Skill", "spawn_agent", "send_input": self = .agent
        case "TodoWrite", "TaskCreate", "TaskUpdate", "EnterPlanMode", "ExitPlanMode", "update_plan": self = .plan
        case "AskUserQuestion": self = .ask
        default:
            if tool.hasPrefix("mcp__") {
                self = .mcp
            } else if tool.hasPrefix("request_user_input") {
                self = .ask
            } else {
                self = .other
            }
        }
    }

    var symbol: String {
        switch self {
        case .edit: "pencil"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .shell: "terminal"
        case .web: "globe"
        case .agent: "sparkles"
        case .mcp: "puzzlepiece.extension"
        case .plan: "checklist"
        case .ask: "questionmark.bubble"
        case .other: "hammer"
        }
    }

    var color: Color {
        switch self {
        case .edit: Palette.violet
        case .read, .search: Palette.sky
        case .shell: Palette.mint
        case .web: Palette.cyan
        case .agent: Palette.pink
        case .mcp: Palette.indigo
        case .plan, .ask: Palette.amber
        case .other: Palette.slate
        }
    }

    var verb: String {
        switch self {
        case .edit: "Editing"
        case .read: "Reading"
        case .search: "Searching"
        case .shell: "Running"
        case .web: "Browsing"
        case .agent: "Delegating"
        case .plan: "Planning"
        case .ask: "Asking"
        case .mcp, .other: "Using"
        }
    }
}

struct ToolActivity: Identifiable, Equatable {
    let id: String
    let tool: String
    let label: String
    let detail: String
    let kind: ToolKind
    let filePath: String?
    let agentID: String?
    let startedAt: Date
    var endedAt: Date?
    var failed = false
    var delta = LineDelta()
    var durationMs: Int?
    /// Codex's reviewer is deciding whether this may run; nothing for you to do.
    var reviewing = false

    var isRunning: Bool { endedAt == nil }
    var isCode: Bool { kind == .shell || kind == .search }
    var isFile: Bool { kind == .edit || kind == .read }
    /// Short text for tight spaces: the detail if there is one, else the tool label.
    var headline: String { detail.isEmpty ? label : detail }

    init(id: String, tool: String, input: [String: Any], agentID: String?, at date: Date) {
        self.id = id
        self.tool = tool
        kind = ToolKind(tool: tool)
        (label, detail) = ToolDescriber.describe(tool: tool, input: input)
        filePath = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
            ?? DiffCounter.patchText(in: input).flatMap { DiffCounter.patchFiles($0).first }
        self.agentID = agentID
        startedAt = date
    }
}

enum ToolDescriber {
    static func describe(tool: String, input: [String: Any]) -> (label: String, detail: String) {
        func text(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func fileName(_ key: String) -> String? {
            text(key).map { ($0 as NSString).lastPathComponent }
        }

        switch tool {
        case "Read", "Edit", "MultiEdit", "Write":
            return (tool, fileName("file_path") ?? "")
        case "NotebookEdit":
            return ("Notebook", fileName("notebook_path") ?? "")
        case "Bash", "exec_command", "shell", "local_shell":
            // Claude sends a string; Codex may send an argv array or `cmd`.
            return ("Bash", shellSummary(commandLine(input["command"]) ?? text("cmd")))
        case "apply_patch":
            let files = DiffCounter.patchText(in: input).map(DiffCounter.patchFiles) ?? []
            let names = files.map { ($0 as NSString).lastPathComponent }
            return ("Patch", names.first.map { names.count > 1 ? "\($0) +\(names.count - 1)" : $0 } ?? "")
        case "exec":
            // Codex code mode: a JS snippet that calls tools. Show the first shell command in it.
            let source = text("input") ?? text("code") ?? ""
            if let command = firstMatch(of: codeModeCommand, in: source) {
                return ("exec", shellSummary(command))
            }
            return ("exec", firstLine(source))
        case "update_plan":
            return ("Plan", "updating plan")
        case "view_image":
            return ("Image", fileName("path") ?? "")
        case "web_search":
            return ("Search", text("query") ?? "")
        case "Grep", "Glob":
            return (tool, text("pattern") ?? "")
        case "WebFetch":
            return ("Fetch", text("url").flatMap { URL(string: $0)?.host } ?? text("url") ?? "")
        case "WebSearch":
            return ("Search", text("query") ?? "")
        case "Task", "Agent":
            return ("Agent", text("description") ?? text("subagent_type") ?? "")
        case "Skill":
            return ("Skill", text("skill") ?? text("command") ?? "")
        case "TodoWrite":
            return ("Todos", "updating plan")
        case "AskUserQuestion":
            let question = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return ("Question", firstLine(question))
        case "ExitPlanMode":
            return ("Plan", "ready for review")
        default:
            if tool.hasPrefix("request_user_input") {
                let question = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
                return ("Question", firstLine(question ?? text("prompt")))
            }
            guard tool.hasPrefix("mcp__") else { return (tool, "") }
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            let server = parts.first ?? "mcp"
            let name = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
            let serverLabel = looksLikeID(server) ? "MCP" : server.replacingOccurrences(of: "_", with: " ")
            return (serverLabel, name)
        }
    }

    /// `cmd:"..."` inside a Codex code-mode snippet, e.g. `tools.exec_command({cmd:"git status"})`.
    private static let codeModeCommand = try! NSRegularExpression(pattern: #"cmd\s*:\s*"((?:[^"\\]|\\.)*)""#)

    private static func firstMatch(of regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// A command as one line: strings as-is; argv arrays joined, unwrapping `bash -lc "…"`.
    private static func commandLine(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let argv = value as? [String], !argv.isEmpty else { return nil }
        let shells: Set<String> = ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"]
        if argv.count >= 3, shells.contains(argv[0]), argv[1] == "-lc" || argv[1] == "-c" {
            return argv[2]
        }
        return argv.joined(separator: " ")
    }

    /// Leading `cd <dir> &&` and `VAR=value;` setup, which Claude prefixes to a lot of commands.
    private static let setupPrefix = try! NSRegularExpression(
        pattern: #"^\s*(?:cd\s+(?:"[^"]*"|'[^']*'|\S+)|[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*))\s*(?:&&|;)\s*"#
    )

    /// The part of a shell command worth reading: its first line, minus setup prefixes,
    /// with the home directory shortened to ~.
    static func shellSummary(_ command: String?) -> String {
        var line = firstLine(command)
        while let match = setupPrefix.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line), range.upperBound < line.endIndex {
            line.removeSubrange(range)
        }
        return line.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func firstLine(_ text: String?) -> String {
        guard let line = text?.split(whereSeparator: \.isNewline).first else { return "" }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func looksLikeID(_ text: String) -> Bool {
        text.count >= 20 && text.filter { $0 == "-" }.count >= 3
    }
}
