import SwiftUI

enum NotchMetrics {
    static let expandedWidth: CGFloat = 600
}

struct NotchRootView: View {
    let model: NotchViewModel
    let store: SessionStore
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    var body: some View {
        let bar = store.presentation
        let geometry = model.geometry
        let expanded = model.hovered
        let active = bar.mode != .idle
        let open = active || expanded

        let topRadius: CGFloat = expanded ? 14 : 8
        let bottomRadius: CGFloat = expanded ? 26 : (open ? 14 : 11)
        let inset = topRadius + (expanded ? 14 : 10)
        // Idle on a notched screen the island shrinks to sit just inside the real notch,
        // so it "emerges" from the hardware when something starts.
        let gap: CGFloat = geometry.hasNotch
            ? (open ? geometry.notchWidth + 18 : max(0, geometry.notchWidth - 8 - 2 * inset))
            : (open ? 16 : 0)
        let rowHeight = open ? geometry.notchHeight : geometry.notchHeight - 2
        let contentWidth = NotchMetrics.expandedWidth - 2 * inset

        // The ears layout is symmetric so the gap stays on the notch, but the black
        // shape only covers each ear's actual content: the short side stays short and
        // leaves the menu bar underneath it alone.
        let ear = max(leadingWidth, trailingWidth)
        let trim = EdgeInsets(top: 0, leading: expanded ? 0 : ear - leadingWidth,
                              bottom: 0, trailing: expanded ? 0 : ear - trailingWidth)

        VStack(spacing: 0) {
            EarsLayout(gap: gap) {
                LeadingEar(bar: bar, expanded: expanded)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.76)) { leadingWidth = width }
                    }
                TrailingEar(bar: bar, store: store, expanded: expanded)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.76)) { trailingWidth = width }
                    }
            }
            .frame(height: rowHeight)
            .fixedSize(horizontal: !expanded, vertical: false)
            .frame(width: expanded ? contentWidth : nil)

            if expanded {
                ExpandedPanel(store: store)
                    .frame(width: contentWidth)
                    .padding(.bottom, 14)
                    .transition(.blurFade)
            }
        }
        .padding(.horizontal, inset)
        .background {
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(Color.black)
                .padding(trim)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    model.shapeFrame = frame
                }
        }
        .overlay {
            if Preferences.shared.glow && active {
                GlowOutline(bar: bar, topRadius: topRadius, bottomRadius: bottomRadius)
                    .padding(trim)
                    .transition(.opacity)
            }
        }
        .jelly(trigger: store.attentionPulse)
        .opacity(geometry.hasNotch || open ? 1 : 0)
        .contextMenu { SettingsMenuItems(store: store) }
        .environment(\.motionEnabled, model.pointerOnScreen || expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: expanded)
        .animation(.spring(response: 0.5, dampingFraction: 0.76), value: bar)
    }
}

/// Two "ears" either side of a gap the width of the hardware notch. Both ears get
/// the same width so the gap stays centred on the notch; content hugs the notch.
struct EarsLayout: Layout {
    var gap: CGFloat

    var animatableData: CGFloat {
        get { gap }
        set { gap = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = gap + 2 * earWidth(subviews)
        let width = proposal.width.map { max($0, natural) } ?? natural
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ear = max(earWidth(subviews), (bounds.width - gap) / 2)
        let size = ProposedViewSize(width: ear, height: bounds.height)
        if subviews.indices.contains(0) {
            subviews[0].place(at: CGPoint(x: bounds.midX - gap / 2, y: bounds.midY), anchor: .trailing, proposal: size)
        }
        if subviews.indices.contains(1) {
            subviews[1].place(at: CGPoint(x: bounds.midX + gap / 2, y: bounds.midY), anchor: .leading, proposal: size)
        }
    }

    private func earWidth(_ subviews: Subviews) -> CGFloat {
        subviews.prefix(2).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }
}

// MARK: - Ears

/// Left of the notch: what Claude is doing. App menus are left-aligned, so this
/// side usually has room for text.
private struct LeadingEar: View {
    let bar: BarPresentation
    let expanded: Bool

    var body: some View {
        HStack(spacing: 7) {
            if bar.mode != .idle {
                StatusGlyph(bar: bar)
                TurnClock(bar: bar)
                if bar.activeCount > 1 {
                    CountBadge(count: bar.activeCount, tint: bar.tint)
                        .transition(.pop)
                }
                ActivityLabel(bar: bar, compact: Preferences.shared.compactBar || expanded)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            } else if expanded {
                SparkView(color: Palette.coral, style: .idle)
                    .frame(width: 15, height: 15)
                Text("Claudebar")
                    .foregroundStyle(Palette.dim)
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        .fixedSize()
    }
}

/// Right of the notch: just numbers and a level meter. Status items crowd in
/// from the right, so this side stays short.
private struct TrailingEar: View {
    let bar: BarPresentation
    let store: SessionStore
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            if bar.mode != .idle {
                if bar.added > 0 || bar.removed > 0 {
                    DiffText(added: bar.added, removed: bar.removed)
                }
                MiniMeter(tint: bar.tint, mode: bar.mode)
            } else if expanded {
                let stats = store.today
                if stats.added + stats.removed > 0 {
                    DiffText(added: stats.added, removed: stats.removed)
                } else {
                    Text("idle").foregroundStyle(Palette.faint)
                }
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }
}

private struct StatusGlyph: View {
    let bar: BarPresentation

    var body: some View {
        ZStack {
            switch bar.mode {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Palette.green)
                    .shadow(color: Palette.green.opacity(0.9), radius: 4)
                    .transition(.pop)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.red)
                    .transition(.pop)
            case .interrupted:
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.slate)
                    .transition(.pop)
            case .waiting:
                SparkView(color: Palette.amber, style: .waiting, agent: bar.agent)
                    .transition(.pop)
            case .working, .compacting, .idle:
                SparkView(color: bar.tint, style: bar.symbol == nil ? .thinking : .busy, agent: bar.agent)
                    .transition(.pop)
            }
        }
        .frame(width: 16, height: 16)
        .overlay {
            if bar.mode == .done {
                BurstView(start: bar.modeSince, color: Palette.green)
            }
        }
    }
}

private struct TurnClock: View {
    let bar: BarPresentation

    var body: some View {
        Group {
            if let start = bar.turnStart {
                if bar.mode.isTerminal, let end = bar.turnEnd {
                    Text(Fmt.clock(end.timeIntervalSince(start)))
                } else {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Fmt.clock(context.date.timeIntervalSince(start)))
                    }
                }
            }
        }
        .foregroundStyle(bar.tint)
    }
}

private struct ActivityLabel: View {
    let bar: BarPresentation
    /// Icon only, for crowded menu bars.
    let compact: Bool

    var body: some View {
        switch bar.mode {
        case .working:
            if let detail = bar.detail {
                HStack(spacing: 5) {
                    if let symbol = bar.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(bar.tint)
                    }
                    if !compact {
                        Text(detail).foregroundStyle(Palette.dim)
                    }
                }
                .id(detail)
                .transition(.blurFade)
            } else if !compact {
                Text("thinking…")
                    .foregroundStyle(Palette.dim)
                    .transition(.blurFade)
            }
        case .waiting:
            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10, weight: .bold))
                if !compact {
                    Text(bar.detail ?? "needs you")
                }
            }
            .foregroundStyle(Palette.amber)
        case .compacting:
            if !compact {
                Text("compacting…").foregroundStyle(Palette.indigo)
            }
        case .done:
            Text("done").foregroundStyle(Palette.green)
        case .failed:
            if !compact {
                Text(bar.detail ?? "failed").foregroundStyle(Palette.red)
            }
        case .interrupted:
            Text("stopped").foregroundStyle(Palette.slate)
        case .idle:
            EmptyView()
        }
    }
}
