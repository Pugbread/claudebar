import AppKit
import SwiftUI

enum BarMode: Equatable {
    case idle, working, waiting, compacting, done, failed, interrupted

    var isTerminal: Bool { self == .done || self == .failed || self == .interrupted }
}

/// Everything the collapsed bar needs, flattened so SwiftUI can diff and animate it.
struct BarPresentation: Equatable {
    var mode: BarMode = .idle
    var sessionID: String?
    var agent: Agent = .claude
    var tint: Color = Palette.slate
    var glow: [Color] = [Palette.slate]
    var turnStart: Date?
    var turnEnd: Date?
    var modeSince: Date = .distantPast
    var added = 0
    var removed = 0
    var detail: String?
    var symbol: String?
    var activeCount = 0

    static let idle = BarPresentation()
}

@MainActor @Observable
final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    private(set) var headlineID: String?
    private(set) var clock = Date()
    private(set) var recentTurns: [TurnSummary] = []
    private(set) var today = DayStats.load()
    private(set) var eventsReceived = 0
    /// Bumped whenever the bar should do its attention wobble.
    private(set) var attentionPulse = 0

    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var sessionsDirty = false
    @ObservationIgnored private let prefs = Preferences.shared
    @ObservationIgnored private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func start() {
        restoreSessions()
        schedule(every: 1) { $0.tick() }
        schedule(every: 1.5) { $0.pollTranscripts() }
        schedule(every: 5) {
            $0.sweep()
            $0.saveSessions()
        }
    }

    private func schedule(every interval: TimeInterval, _ action: @escaping @MainActor (SessionStore) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    // MARK: - Events

    func handle(_ env: HookEnvelope) {
        eventsReceived += 1
        sessionsDirty = true
        let session = session(for: env)
        let now = env.receivedAt
        let agent = env.agentID
        session.lastEventAt = now
        if let model = env.string("model") { session.model = model }

        switch env.event {
        case "SessionStart":
            if let title = env.string("session_title") { session.title = title }
            if let context = env.int("context_tokens") { session.contextTokens = context }
            session.needsTranscriptPoll = true

        case "UserPromptSubmit":
            // Turns started by the system (task notifications, wakeups) carry markup, not
            // something you typed; keep showing your last real prompt for those.
            let prompt = env.string("prompt")
            let typed = ["system", "poll_event"].contains(env.string("source") ?? "") || prompt?.hasPrefix("<") == true
                ? nil : prompt
            session.beginTurn(prompt: typed, at: now)

        case "PreToolUse":
            guard let tool = env.string("tool_name") else { break }
            let id = env.string("tool_use_id") ?? UUID().uuidString
            // Async hooks can occasionally land out of order; a Post already seen wins.
            guard !session.hasFinished(toolID: id) else { break }
            session.ensureTurn(at: now)
            // Claude can't start another tool while a permission prompt is open, so one starting
            // means the prompt was answered even if we missed which tool it was for.
            if session.agent == .claude, session.phase == .waiting, now.timeIntervalSince(session.phaseSince) > 0.5 {
                session.clearWaiting(at: now)
            }
            session.startTool(ToolActivity(id: id, tool: tool, input: env.dict("tool_input"), agentID: agent, at: now))
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" || tool.hasPrefix("request_user_input") {
                session.setWaiting(tool == "ExitPlanMode" ? "Plan ready for review" : "\(session.agent.name) has a question",
                                   tool: tool, agentID: agent, at: now)
                attention(for: session)
            }

        case "PostToolUse", "PostToolUseFailure":
            let tool = env.string("tool_name") ?? ""
            let failed = env.event == "PostToolUseFailure"
            let delta = failed ? nil : DiffCounter.delta(tool: tool, input: env.dict("tool_input"), response: env.payload["tool_response"])
            session.ensureTurn(at: now)
            session.finishTool(id: env.string("tool_use_id") ?? "", failed: failed, delta: delta,
                               durationMs: env.int("duration_ms"), at: now)
            if !session.isDemo {
                updateToday { stats in
                    stats.tools += 1
                    if let delta {
                        stats.added += delta.added
                        stats.removed += delta.removed
                    }
                }
            }
            if failed, env.bool("is_interrupt") == true, agent == nil {
                endTurn(session, outcome: .interrupted, at: now)
            }

        case "PermissionRequest":
            let tool = env.string("tool_name") ?? "tool"
            let (label, detail) = ToolDescriber.describe(tool: tool, input: env.dict("tool_input"))
            if session.agent == .codex, CodexConfig.autoReviewsApprovals {
                session.markReviewing(toolUseID: env.string("tool_use_id"), tool: tool, target: detail, agentID: agent)
            } else {
                session.setWaiting(detail.isEmpty ? "Allow \(label)?" : "Allow \(label): \(detail)",
                                   toolUseID: env.string("tool_use_id"), tool: tool, target: detail, agentID: agent, at: now)
                attention(for: session)
            }

        case "PermissionDenied", "ElicitationResult":
            session.clearWaiting(at: now)

        case "Notification":
            let type = env.string("notification_type")
            if type == "permission_prompt" || type == "elicitation_dialog", session.phase != .waiting {
                session.setWaiting(env.string("message") ?? "Claude needs your input", tool: nil, agentID: agent, at: now)
                attention(for: session)
            }

        case "Elicitation":
            session.setWaiting(env.string("message") ?? "Input requested", tool: nil, agentID: agent, at: now)
            attention(for: session)

        case "SubagentStart":
            if let id = env.string("agent_id") { session.subagents.insert(id) }

        case "SubagentStop":
            if let id = env.string("agent_id") { session.subagents.remove(id) }

        case "PreCompact":
            session.beginCompact(at: now)

        case "PostCompact":
            session.endCompact(at: now)

        case "MessageDisplay":
            if agent == nil, let line = Self.lastMeaningfulLine(env.string("delta")) {
                session.lastLine = line
            }

        case "Stop":
            guard agent == nil else { break }
            let tasks = env.payload["background_tasks"] as? [[String: Any]] ?? []
            session.backgroundTasks = tasks.filter { ["running", "pending"].contains($0["status"] as? String ?? "") }.count
            if let message = Self.lastMeaningfulLine(env.string("last_assistant_message")) {
                session.lastLine = message
            }
            endTurn(session, outcome: .done, at: now)
            if session.agent == .codex { refreshCodexTitle(session) }

        case "Interrupt":
            // Codex: the turn was interrupted (Claude's interrupts are caught from its transcript).
            endTurn(session, outcome: .interrupted, at: now)

        case "StopFailure":
            let error = env.string("error_details") ?? env.string("error") ?? "error"
            session.errorText = Fmt.truncate(error.replacingOccurrences(of: "_", with: " "), 40)
            endTurn(session, outcome: .failed, at: now)

        case "SessionEnd":
            sessions[session.id] = nil

        default:
            break
        }

        refreshHeadline()
        clock = Date()
    }

    private func session(for env: HookEnvelope) -> Session {
        let session: Session
        if let existing = sessions[env.sessionID] {
            session = existing
        } else {
            session = Session(id: env.sessionID)
            session.agent = env.agent
            session.isDemo = env.isDemo
            sessions[env.sessionID] = session
        }
        if session.cwd.isEmpty, let cwd = env.string("cwd") { session.cwd = cwd }
        if env.agentID == nil, let path = env.string("transcript_path") { session.transcriptPath = path }
        if let bundle = env.hostBundleID { session.hostBundleID = bundle }
        if let term = env.termProgram { session.termProgram = term }
        if session.agentPID == nil, let pid = env.agentPID { session.agentPID = pid }
        // Codex names a thread after its first turn; look until it has one.
        if session.agent == .codex, session.title == nil, Date().timeIntervalSince(session.titleCheckedAt) > 15 {
            refreshCodexTitle(session)
        }
        return session
    }

    /// `quiet` records the turn without the wobble and chime, for turns found to have
    /// ended while Claudebar wasn't running.
    private func endTurn(_ session: Session, outcome: Phase, at date: Date, quiet: Bool = false) {
        guard session.turnEnd == nil else { return }
        if session.turnStart == nil { session.beginTurn(prompt: nil, at: date) }
        session.finishTurn(outcome, at: date)
        session.needsTranscriptPoll = true

        let duration = session.turnDuration ?? 0
        recentTurns.insert(TurnSummary(project: session.displayName, hostBundleID: session.hostBundleID,
                                       outcome: outcome, duration: duration, delta: session.lines,
                                       tools: session.toolCount, endedAt: date), at: 0)
        if recentTurns.count > 8 { recentTurns.removeLast(recentTurns.count - 8) }

        if !session.isDemo {
            updateToday { stats in
                stats.turns += 1
                stats.activeSeconds += duration
            }
        }
        if !quiet, outcome == .done || outcome == .failed {
            attentionPulse += 1
            if outcome == .failed || duration >= 20 {
                chime(outcome == .done ? "Glass" : "Funk", for: session)
            }
        }
    }

    private func attention(for session: Session) {
        attentionPulse += 1
        if Date().timeIntervalSince(session.lastPing) > 10 {
            session.lastPing = Date()
            chime("Tink", for: session)
        }
    }

    /// Plays a sound unless you're already looking at the app that runs the session.
    private func chime(_ name: String, for session: Session) {
        guard prefs.sounds, !session.isDemo else { return }
        if let host = session.hostBundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func updateToday(_ change: (inout DayStats) -> Void) {
        var stats = today
        if stats.day != DayStats.key() { stats = DayStats(day: DayStats.key()) }
        change(&stats)
        today = stats
        stats.save()
    }

    func resetToday() {
        today = DayStats(day: DayStats.key())
        today.save()
    }

    /// Today's Claude time, including turns that are still running.
    func activeSeconds(at now: Date) -> Double {
        let running = sessions.values
            .filter { $0.phase.isWorking && !$0.isDemo && $0.turnEnd == nil }
            .compactMap { $0.turnStart.map { now.timeIntervalSince($0) } }
        return today.activeSeconds + running.reduce(0, +)
    }

    // MARK: - Persistence

    private static var sessionsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudebar/sessions.json")
    }

    /// Written every few seconds when something changed, so a relaunch (update, crash,
    /// reboot) doesn't blank the bar until each session's next event.
    func saveSessions() {
        guard sessionsDirty else { return }
        sessionsDirty = false
        let snapshots = sessions.values.filter { !$0.isDemo }.map(\.snapshot)
        let url = Self.sessionsURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshots).write(to: url, options: .atomic)
        } catch {
            NSLog("Claudebar: couldn't save sessions: \(error)")
        }
    }

    private func restoreSessions() {
        guard let data = try? Data(contentsOf: Self.sessionsURL),
              let snapshots = try? JSONDecoder().decode([SessionSnapshot].self, from: data) else { return }
        let now = Date()
        for snapshot in snapshots {
            if let pid = snapshot.agentPID {
                guard ProcessLookup.isAgent(pid, named: (snapshot.agent ?? .claude).processName) else { continue }
            } else if now.timeIntervalSince(snapshot.lastEventAt) > 30 * 60 {
                continue
            }
            let session = Session(snapshot: snapshot)
            sessions[session.id] = session
            if session.phase.isWorking { reconcile(session) }
        }
        refreshHeadline()
    }

    /// A session restored mid-turn may have finished while Claudebar was down. Its
    /// transcript knows: once a turn is over, the last assistant message's stop_reason
    /// is no longer "tool_use".
    private func reconcile(_ session: Session) {
        guard let path = session.transcriptPath else { return }
        let tail = TranscriptTail(path: path)
        let lines = tail.readNewLines()
        session.tail = tail
        session.needsTranscriptPoll = false

        if session.agent == .codex {
            ingest(lines, into: session)
            if let end = Self.codexTurnEnd(in: lines, formatter: isoFormatter), session.phase.isWorking {
                let date = max(end.at ?? session.lastEventAt, session.turnStart ?? .distantPast)
                endTurn(session, outcome: end.interrupted ? .interrupted : .done, at: date, quiet: true)
            }
            return
        }

        var lastStop: (reason: String?, at: Date?)?
        for line in lines.reversed() where line.range(of: Self.assistantNeedle) != nil {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            lastStop = (message["stop_reason"] as? String, (entry["timestamp"] as? String).flatMap(isoFormatter.date(from:)))
            break
        }
        ingest(lines, into: session)
        if let stop = lastStop, let reason = stop.reason, reason != "tool_use", reason != "pause_turn",
           session.phase.isWorking {
            // Never before the turn's start (it may have been first seen after the fact).
            let end = max(stop.at ?? session.lastEventAt, session.turnStart ?? .distantPast)
            endTurn(session, outcome: .done, at: end, quiet: true)
        }
    }

    // MARK: - Headline

    /// Which session the collapsed bar is about: anything waiting on you, then a
    /// turn that just finished, then the working session (sticky so two busy
    /// sessions don't make the bar flip back and forth).
    private func refreshHeadline() {
        let now = Date()
        let all = Array(sessions.values)
        if let waiting = all.filter({ $0.phase == .waiting }).max(by: { $0.phaseSince < $1.phaseSince }) {
            headlineID = waiting.id
            return
        }
        if let flash = all.filter({ $0.phase.isTerminal && now.timeIntervalSince($0.phaseSince) < $0.phase.flashDuration })
            .max(by: { $0.phaseSince < $1.phaseSince }) {
            headlineID = flash.id
            return
        }
        if let current = headlineID.flatMap({ sessions[$0] }), current.phase.isWorking { return }
        headlineID = all.filter { $0.phase.isWorking }.max(by: { $0.lastEventAt < $1.lastEventAt })?.id
    }

    var presentation: BarPresentation {
        let now = clock
        guard let session = headlineID.flatMap({ sessions[$0] }) else { return .idle }

        var bar = BarPresentation()
        bar.sessionID = session.id
        bar.agent = session.agent
        bar.activeCount = sessions.values.filter { $0.phase.isWorking }.count
        bar.turnStart = session.turnStart
        bar.turnEnd = session.turnEnd
        bar.modeSince = session.phaseSince
        bar.added = session.lines.added
        bar.removed = session.lines.removed

        switch session.phase {
        case .thinking, .tool:
            bar.mode = .working
            if let tool = session.currentTool ?? session.recentTool(within: 1.2, now: now) {
                bar.tint = tool.kind.color
                bar.symbol = tool.isRunning && tool.reviewing ? "checkmark.shield" : tool.kind.symbol
                bar.detail = Fmt.truncate(tool.headline, 26, middle: tool.isFile)
            } else {
                bar.tint = session.agent.accent
            }
        case .waiting:
            bar.mode = .waiting
            bar.tint = Palette.amber
            bar.detail = Fmt.truncate(session.waitingDetail ?? "needs you", 30)
        case .compacting:
            bar.mode = .compacting
            bar.tint = Palette.indigo
            if session.turnEnd != nil || session.turnStart == nil { bar.turnStart = session.phaseSince }
        case .done, .failed, .interrupted:
            guard now.timeIntervalSince(session.phaseSince) < session.phase.flashDuration else { return .idle }
            bar.mode = session.phase == .done ? .done : session.phase == .failed ? .failed : .interrupted
            bar.tint = session.tint
            bar.detail = session.phase == .failed ? session.errorText : nil
        case .idle:
            return .idle
        }
        bar.glow = Self.glow(for: bar.mode, tint: bar.tint, agent: session.agent)
        return bar
    }

    private static func glow(for mode: BarMode, tint: Color, agent: Agent) -> [Color] {
        switch mode {
        case .working where agent == .codex: [tint, Palette.codexLavender, Palette.codex, Palette.codexDeep]
        case .working: [tint, Palette.coral, Palette.pink, Palette.violet]
        case .waiting: [Palette.amber, Palette.orange, Palette.amber, Palette.butter]
        case .compacting: [Palette.indigo, Palette.violet, Palette.cyan]
        case .done: [Palette.green, Palette.mint, Palette.cyan, Palette.green]
        case .failed: [Palette.red, Palette.pink, Palette.red]
        case .interrupted: [Palette.slate, Palette.faint]
        case .idle: [Palette.slate]
        }
    }

    /// Sessions for the expanded panel: anything working, plus turns finished in the last hour.
    /// The bar's headline session comes first so the big card matches what the bar shows.
    var visibleSessions: [Session] {
        let now = clock
        let headline = headlineID
        func rank(_ session: Session) -> Int {
            if session.id == headline { return 0 }
            switch session.phase {
            case .waiting: return 1
            case .thinking, .tool, .compacting: return 2
            default: return 3
            }
        }
        return sessions.values
            .filter { $0.phase.isWorking || ($0.turnEnd.map { now.timeIntervalSince($0) < 3600 } ?? false) }
            .sorted {
                let (a, b) = (rank($0), rank($1))
                if a != b { return a < b }
                // Working: oldest turn first, so cards don't reshuffle. Finished: most recent first.
                if $0.phase.isWorking { return ($0.turnStart ?? .distantPast) < ($1.turnStart ?? .distantPast) }
                return ($0.turnEnd ?? .distantPast) > ($1.turnEnd ?? .distantPast)
            }
    }

    // MARK: - Host app

    func activateHost(of session: Session) {
        let fallback = session.agent == .codex ? AppIcons.codexBundleID : nil
        guard let bundle = session.hostBundleID ?? Self.bundleID(forTerminal: session.termProgram) ?? fallback,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func bundleID(forTerminal term: String?) -> String? {
        switch term {
        case "Apple_Terminal": "com.apple.Terminal"
        case "iTerm.app": "com.googlecode.iterm2"
        case "vscode": "com.microsoft.VSCode"
        case "ghostty": "com.mitchellh.ghostty"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        case "WezTerm": "com.github.wez.wezterm"
        default: nil
        }
    }

    // MARK: - Timers

    private func tick() {
        let now = Date()
        let needsClock = sessions.values.contains {
            $0.phase.isWorking || ($0.phase.isTerminal && now.timeIntervalSince($0.phaseSince) < $0.phase.flashDuration + 1.5)
        }
        guard needsClock else { return }
        refreshHeadline()
        clock = now
    }

    private func sweep() {
        let now = Date()
        for session in Array(sessions.values) {
            if let pid = session.agentPID, !ProcessLookup.isAlive(pid) {
                sessions[session.id] = nil
            } else if session.isDemo, now.timeIntervalSince(session.lastEventAt) > 30 {
                sessions[session.id] = nil
            } else if session.phase.isWorking, now.timeIntervalSince(session.lastEventAt) > 45 * 60 {
                session.markIdle()
            } else if !session.phase.isWorking, now.timeIntervalSince(session.lastEventAt) > 3 * 3600 {
                sessions[session.id] = nil
            }
        }
        if today.day != DayStats.key() { today = DayStats(day: DayStats.key()) }
        refreshHeadline()
    }

    // MARK: - Transcripts (token counts + interrupt detection)

    private static let usageNeedle = Data("\"usage\"".utf8)
    private static let assistantNeedle = Data("\"type\":\"assistant\"".utf8)
    private static let titleNeedle = Data("\"type\":\"custom-title\"".utf8)
    private static let interruptNeedle = Data("[Request interrupted by user".utf8)

    private func pollTranscripts() {
        for session in sessions.values where session.phase.isWorking || session.needsTranscriptPoll {
            guard let path = session.transcriptPath else { continue }
            session.needsTranscriptPoll = false
            if session.tail?.path != path { session.tail = TranscriptTail(path: path) }
            guard let lines = session.tail?.readNewLines(), !lines.isEmpty else { continue }
            session.lastEventAt = max(session.lastEventAt, Date().addingTimeInterval(-1))
            ingest(lines, into: session)
        }
    }

    private func ingest(_ lines: [Data], into session: Session) {
        if session.agent == .codex {
            ingestCodex(lines, into: session)
            return
        }
        for line in lines {
            if line.range(of: Self.usageNeedle) != nil {
                guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      entry["type"] as? String == "assistant",
                      entry["isSidechain"] as? Bool != true,
                      let message = entry["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                func tokens(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
                let context = tokens("input_tokens") + tokens("cache_read_input_tokens") + tokens("cache_creation_input_tokens")
                if context > 0 { session.contextTokens = context }
                if let model = message["model"] as? String, !model.hasPrefix("<") { session.model = model }
                if let id = message["id"] as? String, let start = session.turnStart,
                   let stamp = (entry["timestamp"] as? String).flatMap(isoFormatter.date(from:)),
                   stamp >= start.addingTimeInterval(-2) {
                    session.turnOutput[id] = tokens("output_tokens")
                }
            } else if line.range(of: Self.titleNeedle) != nil {
                if let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let title = (entry["customTitle"] as? String)?.nilIfEmpty {
                    session.title = title
                }
            } else if line.range(of: Self.interruptNeedle) != nil, session.phase.isWorking {
                guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      entry["type"] as? String == "user",
                      Self.isInterruptMarker(entry["message"]),
                      let start = session.turnStart,
                      let stamp = (entry["timestamp"] as? String).flatMap(isoFormatter.date(from:)),
                      stamp >= start else { continue }
                endTurn(session, outcome: .interrupted, at: Date())
                refreshHeadline()
            }
        }
        session.outputTokens = session.turnOutput.values.reduce(0, +)
        sessionsDirty = true
    }

    // MARK: - Codex transcripts

    private static let tokenCountNeedle = Data("\"token_count\"".utf8)
    private static let turnContextNeedle = Data("\"turn_context\"".utf8)
    private static let taskCompleteNeedle = Data("\"task_complete\"".utf8)
    private static let turnAbortedNeedle = Data("\"turn_aborted\"".utf8)
    private static let taskStartedNeedle = Data("\"task_started\"".utf8)

    /// Codex rollouts log a `token_count` event after each model call: the last call's
    /// input is the context size, and the running output total gives this turn's output.
    private func ingestCodex(_ lines: [Data], into session: Session) {
        for line in lines {
            if line.range(of: Self.tokenCountNeedle) != nil {
                guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = entry["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any] else { continue }
                let last = info["last_token_usage"] as? [String: Any] ?? [:]
                let total = info["total_token_usage"] as? [String: Any] ?? [:]
                func tokens(_ usage: [String: Any], _ key: String) -> Int? { (usage[key] as? NSNumber)?.intValue }
                if let context = tokens(last, "input_tokens"), context > 0 { session.contextTokens = context }
                if let window = (info["model_context_window"] as? NSNumber)?.intValue { session.contextWindow = window }
                if let output = tokens(total, "output_tokens") {
                    if session.codexTurnBase == nil, session.turnStart != nil {
                        session.codexTurnBase = output - (tokens(last, "output_tokens") ?? 0)
                    }
                    session.codexOutputTotal = output
                }
            } else if line.range(of: Self.turnContextNeedle) != nil {
                if let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let model = (entry["payload"] as? [String: Any])?["model"] as? String {
                    session.model = model
                }
            }
        }
        if let total = session.codexOutputTotal, let base = session.codexTurnBase {
            session.outputTokens = max(0, total - base)
        }
        sessionsDirty = true
    }

    /// Whether the rollout's latest turn event is a completion or an abort.
    private static func codexTurnEnd(in lines: [Data], formatter: ISO8601DateFormatter) -> (interrupted: Bool, at: Date?)? {
        for line in lines.reversed() {
            let complete = line.range(of: taskCompleteNeedle) != nil
            let aborted = line.range(of: turnAbortedNeedle) != nil
            if line.range(of: taskStartedNeedle) != nil { return nil }
            guard complete || aborted else { continue }
            let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            return (aborted, (entry?["timestamp"] as? String).flatMap(formatter.date(from:)))
        }
        return nil
    }

    /// Codex keeps thread names (its chat titles) in ~/.codex/session_index.jsonl.
    private func refreshCodexTitle(_ session: Session) {
        session.titleCheckedAt = Date()
        let index = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/session_index.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: index) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        guard let data = try? handle.readToEnd() else { return }
        let needle = Data("\"\(session.id)\"".utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: needle) != nil {
            if let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let name = (entry["thread_name"] as? String)?.nilIfEmpty {
                session.title = name
                return
            }
        }
    }

    private static func isInterruptMarker(_ message: Any?) -> Bool {
        let content = (message as? [String: Any])?["content"]
        if let text = content as? String { return text.hasPrefix("[Request interrupted by user") }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.contains { ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true }
    }

    private static func lastMeaningfulLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.count > 1 && !$0.hasPrefix("```") && !$0.hasPrefix("|") }
        guard var line else { return nil }
        while let first = line.first, "#>-*• ".contains(first) { line.removeFirst() }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return line.nilIfEmpty.map { Fmt.truncate($0, 180) }
    }

    // MARK: - Debug

    func debugSnapshot() -> Data {
        let list: [[String: Any]] = sessions.values.map { session in
            [
                "id": session.id,
                "project": session.displayName,
                "agent": session.agent.rawValue,
                "phase": session.phase.rawValue,
                "host": session.hostBundleID ?? NSNull(),
                "pid": session.agentPID.map { Int($0) } ?? NSNull(),
                "model": session.model ?? NSNull(),
                "tool": session.currentTool.map { "\($0.label) \($0.detail)" } ?? NSNull(),
                "added": session.lines.added,
                "removed": session.lines.removed,
                "tools": session.toolCount,
                "context_tokens": session.contextTokens ?? NSNull(),
                "output_tokens": session.outputTokens,
                "subagents": session.subagents.count,
                "last_line": session.lastLine ?? NSNull(),
                "waiting": session.waitingDetail ?? NSNull(),
            ]
        }
        let root: [String: Any] = [
            "events_received": eventsReceived,
            "headline": headlineID ?? NSNull(),
            "mode": "\(presentation.mode)",
            "sessions": list,
            "today": ["turns": today.turns, "active_seconds": Int(today.activeSeconds),
                      "added": today.added, "removed": today.removed, "tools": today.tools],
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
