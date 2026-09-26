import SwiftUI

enum Phase: String {
    case idle, thinking, tool, waiting, compacting, done, failed, interrupted

    var isWorking: Bool { self == .thinking || self == .tool || self == .waiting || self == .compacting }
    var isTerminal: Bool { self == .done || self == .failed || self == .interrupted }

    /// How long a finished turn keeps the collapsed bar open.
    var flashDuration: TimeInterval {
        switch self {
        case .done: 6
        case .failed: 9
        case .interrupted: 3
        default: 0
        }
    }
}

/// Which coding agent a session belongs to.
enum Agent: String, Codable {
    case claude, codex

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Colour of the thinking state, so you can tell whose session the bar is showing.
    var accent: Color {
        switch self {
        case .claude: Palette.coral
        case .codex: Palette.codex
        }
    }

    var processName: String { rawValue }
}

/// What survives a Claudebar relaunch: everything the bar and cards show except the tool log.
struct SessionSnapshot: Codable {
    var id: String
    var agent: Agent?
    var cwd: String
    var title: String?
    var hostBundleID: String?
    var termProgram: String?
    var agentPID: pid_t?
    var transcriptPath: String?
    var model: String?
    var phase: String
    var phaseSince: Date
    var lastEventAt: Date
    var turnStart: Date?
    var turnEnd: Date?
    var prompt: String?
    var added: Int
    var removed: Int
    var files: [String: LineDelta]
    var toolCount: Int
    var waitingDetail: String?
    var lastLine: String?
    var errorText: String?
    var contextTokens: Int?
    var contextWindow: Int?
    var outputTokens: Int
}

/// One Claude Code session (a CLI process, an IDE panel, or a desktop Code tab).
@MainActor @Observable
final class Session: Identifiable {
    nonisolated let id: String
    var agent: Agent = .claude
    var cwd = ""
    var title: String?
    var hostBundleID: String?
    var termProgram: String?
    var agentPID: pid_t?
    var transcriptPath: String?
    var model: String?
    var isDemo = false

    private(set) var phase: Phase = .idle
    private(set) var phaseSince = Date()
    var lastEventAt = Date()

    private(set) var turnStart: Date?
    private(set) var turnEnd: Date?
    private(set) var prompt: String?
    private(set) var lines = LineDelta()
    private(set) var files: [String: LineDelta] = [:]
    private(set) var toolCount = 0
    private(set) var activities: [ToolActivity] = []
    private(set) var running: [String] = []
    private(set) var waitingDetail: String?
    var subagents: Set<String> = []
    var lastLine: String?
    var errorText: String?
    var contextTokens: Int?
    /// Known for Codex, which records the model's window in its transcript.
    var contextWindow: Int?
    var outputTokens = 0
    var backgroundTasks = 0

    @ObservationIgnored private var waitingToolID: String?
    @ObservationIgnored private var finishedIDs: Set<String> = []
    @ObservationIgnored private var compactReturn: (phase: Phase, since: Date)?
    @ObservationIgnored var turnOutput: [String: Int] = [:]
    /// Codex reports cumulative output tokens; the turn's share is measured from this base.
    @ObservationIgnored var codexOutputTotal: Int?
    @ObservationIgnored var codexTurnBase: Int?
    @ObservationIgnored var tail: TranscriptTail?
    @ObservationIgnored var needsTranscriptPoll = true
    @ObservationIgnored var lastPing = Date.distantPast
    @ObservationIgnored var titleCheckedAt = Date.distantPast

    init(id: String) {
        self.id = id
    }

    init(snapshot: SessionSnapshot) {
        id = snapshot.id
        agent = snapshot.agent ?? .claude
        cwd = snapshot.cwd
        title = snapshot.title
        hostBundleID = snapshot.hostBundleID
        termProgram = snapshot.termProgram
        agentPID = snapshot.agentPID
        transcriptPath = snapshot.transcriptPath
        model = snapshot.model
        // The tool log isn't persisted, so a session caught mid-tool comes back as thinking.
        let restored = Phase(rawValue: snapshot.phase) ?? .idle
        phase = restored == .tool ? .thinking : restored
        phaseSince = snapshot.phaseSince
        lastEventAt = snapshot.lastEventAt
        turnStart = snapshot.turnStart
        turnEnd = snapshot.turnEnd
        prompt = snapshot.prompt
        lines = LineDelta(added: snapshot.added, removed: snapshot.removed)
        files = snapshot.files
        toolCount = snapshot.toolCount
        waitingDetail = snapshot.waitingDetail
        lastLine = snapshot.lastLine
        errorText = snapshot.errorText
        contextTokens = snapshot.contextTokens
        contextWindow = snapshot.contextWindow
        outputTokens = snapshot.outputTokens
    }

    var snapshot: SessionSnapshot {
        SessionSnapshot(id: id, agent: agent, cwd: cwd, title: title, hostBundleID: hostBundleID, termProgram: termProgram,
                        agentPID: agentPID, transcriptPath: transcriptPath, model: model,
                        phase: phase.rawValue, phaseSince: phaseSince, lastEventAt: lastEventAt,
                        turnStart: turnStart, turnEnd: turnEnd, prompt: prompt,
                        added: lines.added, removed: lines.removed, files: files, toolCount: toolCount,
                        waitingDetail: waitingDetail, lastLine: lastLine, errorText: errorText,
                        contextTokens: contextTokens, contextWindow: contextWindow, outputTokens: outputTokens)
    }

    // MARK: Derived

    var folderName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var displayName: String {
        title?.nilIfEmpty ?? folderName.nilIfEmpty ?? agent.name
    }

    var currentTool: ToolActivity? {
        guard let id = running.last else { return nil }
        return activities.last { $0.id == id }
    }

    /// The tool that finished moments ago — keeps the bar from flickering to
    /// "thinking" between back-to-back tool calls.
    func recentTool(within window: TimeInterval, now: Date) -> ToolActivity? {
        guard let last = activities.last, let end = last.endedAt, now.timeIntervalSince(end) < window else { return nil }
        return last
    }

    var turnDuration: TimeInterval? {
        guard let start = turnStart else { return nil }
        return max(0, (turnEnd ?? Date()).timeIntervalSince(start))
    }

    var tint: Color {
        switch phase {
        case .thinking: agent.accent
        case .tool: currentTool?.kind.color ?? agent.accent
        case .waiting: Palette.amber
        case .compacting: Palette.indigo
        case .done: Palette.green
        case .failed: Palette.red
        case .interrupted, .idle: Palette.slate
        }
    }

    // MARK: Transitions

    func setPhase(_ newPhase: Phase, at date: Date = Date()) {
        guard phase != newPhase else { return }
        phase = newPhase
        phaseSince = date
    }

    func beginTurn(prompt: String?, at date: Date) {
        turnStart = date
        turnEnd = nil
        if let prompt { self.prompt = Self.clean(prompt) }
        lines = LineDelta()
        files = [:]
        toolCount = 0
        activities = []
        running = []
        finishedIDs = []
        waitingDetail = nil
        waitingToolID = nil
        errorText = nil
        lastLine = nil
        turnOutput = [:]
        codexTurnBase = codexOutputTotal
        outputTokens = 0
        setPhase(.thinking, at: date)
    }

    /// Called when work shows up without a UserPromptSubmit: Claudebar launched mid-turn,
    /// a Stop hook sent Claude back to work, or a background task woke the session.
    func ensureTurn(at date: Date) {
        guard let end = turnEnd else {
            if turnStart == nil { beginTurn(prompt: nil, at: date) }
            return
        }
        if date.timeIntervalSince(end) < 8 {
            turnEnd = nil
            setPhase(running.isEmpty ? .thinking : .tool, at: date)
        } else {
            beginTurn(prompt: nil, at: date)
        }
    }

    func hasFinished(toolID: String) -> Bool {
        finishedIDs.contains(toolID)
    }

    func startTool(_ activity: ToolActivity) {
        activities.append(activity)
        if activities.count > 40 { activities.removeFirst(activities.count - 40) }
        running.append(activity.id)
        if phase != .waiting && phase != .compacting {
            setPhase(.tool, at: activity.startedAt)
        }
    }

    func finishTool(id: String, failed: Bool, delta: LineDelta?, durationMs: Int?, at date: Date) {
        finishedIDs.insert(id)
        running.removeAll { $0 == id }
        toolCount += 1

        var filePath: String?
        if let index = activities.lastIndex(where: { $0.id == id }) {
            activities[index].endedAt = date
            activities[index].failed = failed
            activities[index].durationMs = durationMs
            if let delta { activities[index].delta = delta }
            filePath = activities[index].filePath
        }
        if let delta, !delta.isEmpty {
            lines.add(delta)
            files[filePath ?? id, default: LineDelta()].add(delta)
        }

        if phase == .waiting {
            if waitingToolID == nil || waitingToolID == id { clearWaiting(at: date) }
        } else if phase == .tool || phase == .thinking {
            setPhase(running.isEmpty ? .thinking : .tool, at: date)
        }
    }

    /// Links a permission prompt to the running tool it's about, so an unrelated
    /// parallel tool finishing doesn't clear it.
    /// Links a prompt to the tool it's about: by ID when the hook sends one (Codex), else by
    /// the exact command/target, else the latest running call of that tool. Parallel calls are
    /// common, so "the latest Bash" alone can pick a long-running one and strand the prompt.
    func setWaiting(_ detail: String, toolUseID: String? = nil, tool: String?, target: String? = nil,
                    agentID: String?, at date: Date) {
        waitingDetail = detail
        waitingToolID = runningTool(id: toolUseID, tool: tool, target: target, agentID: agentID)?.id
        setPhase(.waiting, at: date)
    }

    /// Codex's own reviewer is deciding on this call: show it, but don't ask for attention.
    func markReviewing(toolUseID: String?, tool: String, target: String, agentID: String?) {
        guard let match = runningTool(id: toolUseID, tool: tool, target: target, agentID: agentID),
              let index = activities.lastIndex(where: { $0.id == match.id }) else { return }
        activities[index].reviewing = true
    }

    private func runningTool(id: String?, tool: String?, target: String?, agentID: String?) -> ToolActivity? {
        if let id, let exact = activities.last(where: { $0.id == id && $0.isRunning }) { return exact }
        guard let tool else { return nil }
        let candidates = activities.filter { $0.isRunning && $0.tool == tool && $0.agentID == agentID }
        return candidates.last { target != nil && $0.detail == target } ?? candidates.last
    }

    func clearWaiting(at date: Date) {
        waitingDetail = nil
        waitingToolID = nil
        guard phase == .waiting else { return }
        setPhase(running.isEmpty ? .thinking : .tool, at: date)
    }

    func beginCompact(at date: Date) {
        guard phase != .compacting else { return }
        compactReturn = (phase, phaseSince)
        setPhase(.compacting, at: date)
    }

    func endCompact(at date: Date) {
        guard phase == .compacting else { return }
        if turnStart != nil && turnEnd == nil {
            setPhase(running.isEmpty ? .thinking : .tool, at: date)
        } else {
            // Manual /compact between turns: restore the old state without re-flashing it.
            phase = compactReturn?.phase ?? .idle
            phaseSince = compactReturn?.since ?? .distantPast
        }
        compactReturn = nil
    }

    func finishTurn(_ outcome: Phase, at date: Date) {
        turnEnd = date
        for index in activities.indices where activities[index].isRunning {
            activities[index].endedAt = date
            activities[index].failed = outcome != .done
        }
        running = []
        waitingDetail = nil
        waitingToolID = nil
        subagents = []
        setPhase(outcome, at: date)
    }

    func markIdle() {
        running = []
        waitingDetail = nil
        waitingToolID = nil
        setPhase(.idle)
    }

    private static func clean(_ prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return Fmt.truncate(line, 200)
    }
}
