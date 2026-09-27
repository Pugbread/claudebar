import SwiftUI

struct ExpandedPanel: View {
    let store: SessionStore
    /// The shelf item whose thumbnail is under the pointer, shown big over the cards.
    @State private var previewing: MediaItem?

    var body: some View {
        let sessions = Array(store.visibleSessions.prefix(4))
        VStack(alignment: .leading, spacing: 10) {
            if !store.media.isEmpty {
                MediaShelf(store: store, previewing: $previewing)
            }
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if sessions.isEmpty {
                        IdleSummary(store: store)
                    } else {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            SessionCard(session: session, primary: index == 0, store: store)
                                .transition(.settle)
                        }
                    }
                    FooterBar(store: store)
                }
                if let item = previewing {
                    MediaPreview(item: item)
                        .id(item.path)
                        .transition(.opacity.combined(with: .offset(y: -8)))
                        .zIndex(1)
                }
            }
        }
        .padding(.top, 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sessions.map(\.id))
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: previewing?.path)
    }
}

extension AnyTransition {
    /// A card arriving or leaving while the panel is open: a short drop and fade.
    static var settle: AnyTransition {
        .opacity.combined(with: .offset(y: -6))
    }
}

// MARK: - Session card

private struct SessionCard: View {
    let session: Session
    let primary: Bool
    let store: SessionStore
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if session.phase == .waiting { waitingBanner }
            if primary {
                if let prompt = session.prompt {
                    Text("“\(prompt)”")
                        .font(.system(size: 11.5).italic())
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                }
                if !session.activities.isEmpty {
                    ActivityList(activities: Array(session.activities.suffix(4)))
                }
                if session.phase.isWorking, let line = session.lastLine {
                    speech(line)
                }
                stats
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.085 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(session.phase == .waiting ? Palette.amber.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { store.activateHost(of: session) }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.activities.map(\.id))
    }

    private var header: some View {
        HStack(spacing: 10) {
            HostIcon(bundleID: session.hostBundleID, agent: session.agent, tint: session.tint, pulsing: session.phase.isWorking)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    if let model = Fmt.model(session.model) ?? (session.agent == .codex ? "Codex" : nil) {
                        Text(model)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.dim)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                StatusLine(session: session)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                SessionClock(session: session)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(session.tint)
                if !session.lines.isEmpty {
                    DiffText(added: session.lines.added, removed: session.lines.removed)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
        }
    }

    private var waitingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
            Text(session.waitingDetail ?? "Claude needs your input")
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 6)
            Text("Open")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Palette.amber))
        }
        .foregroundStyle(Palette.amber)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.amber.opacity(0.12)))
    }

    private func speech(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            SparkView(color: session.agent.accent, style: .thinking, agent: session.agent)
                .frame(width: 11, height: 11)
                .padding(.top, 2)
            Text(line)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.text.opacity(0.8))
                .lineLimit(2)
                .id(line)
                .transition(.blurFade)
        }
        .animation(.easeOut(duration: 0.25), value: line)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            if session.title != nil, !session.folderName.isEmpty {
                Label(session.folderName, systemImage: "folder.fill")
            }
            if let context = session.contextTokens {
                if let window = session.contextWindow, window > 0 {
                    Label("\(Fmt.tokens(context)) / \(Fmt.tokens(window)) context", systemImage: "square.stack.3d.up.fill")
                        .foregroundStyle(Double(context) / Double(window) > 0.85 ? Palette.amber : Palette.faint)
                } else {
                    Label("\(Fmt.tokens(context)) context", systemImage: "square.stack.3d.up.fill")
                }
            }
            if session.outputTokens > 0 {
                Label("\(Fmt.tokens(session.outputTokens)) out", systemImage: "arrow.down.circle.fill")
            }
            if session.toolCount > 0 {
                Label("\(session.toolCount) tools", systemImage: "hammer.fill")
            }
            if !session.files.isEmpty {
                Label("\(session.files.count) files", systemImage: "doc.on.doc.fill")
            }
            if !session.subagents.isEmpty {
                Label("\(session.subagents.count) agents", systemImage: "sparkles")
                    .foregroundStyle(Palette.pink)
            }
            if session.backgroundTasks > 0 {
                Label("\(session.backgroundTasks) in background", systemImage: "clock.arrow.circlepath")
            }
        }
        .labelStyle(TightLabel())
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .foregroundStyle(Palette.faint)
        .lineLimit(1)
    }
}

private struct StatusLine: View {
    let session: Session

    var body: some View {
        Group {
            switch session.phase {
            case .thinking:
                ShimmerText(text: "Thinking…", base: session.agent.accent.opacity(0.8))
            case .compacting:
                ShimmerText(text: "Compacting context…", base: Palette.indigo.opacity(0.9))
            case .tool:
                if let tool = session.currentTool {
                    HStack(spacing: 5) {
                        Image(systemName: tool.kind.symbol)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(tool.kind.color)
                        Text(tool.reviewing ? "Auto-reviewing" : tool.kind.verb).foregroundStyle(Palette.dim)
                        Text(tool.headline)
                            .font(.system(size: 11, design: tool.isCode ? .monospaced : .default))
                            .foregroundStyle(Palette.text.opacity(0.75))
                            .truncationMode(tool.isFile ? .middle : .tail)
                    }
                } else {
                    Text("Working…")
                }
            case .waiting:
                Text("Waiting for you").foregroundStyle(Palette.amber)
            case .done, .failed, .interrupted:
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("\(outcome) · \(Fmt.relative(session.turnEnd ?? .now, now: context.date))")
                }
                .foregroundStyle(session.phase == .failed ? Palette.red : Palette.dim)
            case .idle:
                Text("Idle")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Palette.dim)
        .lineLimit(1)
    }

    private var outcome: String {
        switch session.phase {
        case .failed: session.errorText.map { "Failed: \($0)" } ?? "Failed"
        case .interrupted: "Interrupted"
        default: "Done"
        }
    }
}

private struct SessionClock: View {
    let session: Session

    var body: some View {
        if let start = session.turnStart {
            if let end = session.turnEnd {
                Text(Fmt.clock(end.timeIntervalSince(start)))
            } else {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Fmt.clock(context.date.timeIntervalSince(start)))
                }
            }
        }
    }
}

// MARK: - Activity

private struct ActivityList: View {
    let activities: [ToolActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(activities) { activity in
                ActivityRow(activity: activity)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ActivityRow: View {
    let activity: ToolActivity

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: activity.kind.symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(activity.kind.color)
                .frame(width: 14)
            Text(activity.label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.text.opacity(0.85))
            Text(activity.detail)
                .font(.system(size: 11, design: activity.isCode ? .monospaced : .default))
                .foregroundStyle(Palette.dim)
                .lineLimit(1)
                .truncationMode(activity.isFile ? .middle : .tail)
            if activity.agentID != nil {
                Text("agent")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.pink)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.pink.opacity(0.15)))
            }
            Spacer(minLength: 6)
            trailing
        }
        .opacity(activity.isRunning ? 1 : 0.75)
    }

    @ViewBuilder private var trailing: some View {
        if activity.isRunning && activity.reviewing {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield")
                Text("reviewing")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Palette.amber.opacity(0.75))
        } else if activity.isRunning {
            HStack(spacing: 5) {
                LiveElapsed(since: activity.startedAt)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.faint)
                Spinner(color: activity.kind.color)
            }
        } else if activity.failed {
            Text("failed")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.red)
        } else if !activity.delta.isEmpty {
            DiffText(added: activity.delta.added, removed: activity.delta.removed)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        } else {
            Text(Fmt.short(elapsed))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.faint)
        }
    }

    private var elapsed: TimeInterval {
        if let ms = activity.durationMs, ms > 0 { return Double(ms) / 1000 }
        return (activity.endedAt ?? .now).timeIntervalSince(activity.startedAt)
    }
}

// MARK: - Idle + footer

private struct IdleSummary: View {
    let store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SparkView(color: Palette.coral, style: .idle)
                    .frame(width: 15, height: 15)
                Text(store.eventsReceived == 0 ? "Listening for Claude Code and Codex" : "All quiet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
            }
            if store.recentTurns.isEmpty {
                Text(store.eventsReceived == 0
                     ? "No hook events yet. Run scripts/install.sh, then start a new Claude Code or Codex session."
                     : "No sessions running. Finished turns show up here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.dim)
            } else {
                ForEach(store.recentTurns.prefix(3)) { turn in
                    RecentTurnRow(turn: turn)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.card))
    }
}

private struct RecentTurnRow: View {
    let turn: TurnSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
            Text(turn.project)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Text(Fmt.clock(turn.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.dim)
            if !turn.delta.isEmpty {
                DiffText(added: turn.delta.added, removed: turn.delta.removed)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Fmt.relative(turn.endedAt, now: context.date))
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.faint)
        }
    }

    private var symbol: String {
        switch turn.outcome {
        case .failed: "exclamationmark.circle.fill"
        case .interrupted: "stop.circle.fill"
        default: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch turn.outcome {
        case .failed: Palette.red
        case .interrupted: Palette.slate
        default: Palette.green
        }
    }
}

private struct FooterBar: View {
    let store: SessionStore

    var body: some View {
        let stats = store.today
        HStack(spacing: 12) {
            Text("TODAY")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(Palette.faint)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(Fmt.hours(store.activeSeconds(at: context.date)), systemImage: "clock.fill")
            }
            Label("\(stats.turns) turns", systemImage: "arrow.triangle.turn.up.right.circle.fill")
            Label("\(stats.tools) tools", systemImage: "hammer.fill")
            DiffText(added: stats.added, removed: stats.removed)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Spacer(minLength: 0)
            Menu {
                SettingsMenuItems(store: store)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(TightLabel())
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(Palette.dim)
        .padding(.horizontal, 6)
    }
}

struct SettingsMenuItems: View {
    let store: SessionStore
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Toggle("Sounds", isOn: $prefs.sounds)
        Toggle("Glow effects", isOn: $prefs.glow)
        Toggle("Compact bar", isOn: $prefs.compactBar)
        Toggle("Show on all displays", isOn: $prefs.allDisplays)
        Toggle("Launch at login", isOn: $prefs.launchAtLogin)
        Divider()
        Button("Play demo") { Demo.play(on: store) }
        Button("Reset today's stats") { store.resetToday() }
        Divider()
        Button("Quit Claudebar") { NSApp.terminate(nil) }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}
