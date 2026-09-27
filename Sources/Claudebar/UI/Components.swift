import AppKit
import SwiftUI

/// One shared frame clock for the SwiftUI-driven animations (the expanded panel's
/// small pieces), so they all redraw on the same frames. The always-on bar
/// animations live in LayerViews.swift and cost nothing per frame.
enum Motion {
    static let frameInterval = 1.0 / 30
}

private struct MotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False on displays the pointer isn't on: their islands still update, but don't animate.
    var motionEnabled: Bool {
        get { self[MotionEnabledKey.self] }
        set { self[MotionEnabledKey.self] = newValue }
    }
}

/// Drives `content` every frame while `active`; otherwise renders it once, with no
/// timeline at all (a paused TimelineView still keeps the display link ticking).
struct FrameClock<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.motionEnabled) private var motionEnabled

    var body: some View {
        if active && motionEnabled {
            TimelineView(.animation(minimumInterval: Motion.frameInterval)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }
}

// MARK: - Notch shape

/// Everything that decides the island's outline, animated as one value. The island is drawn
/// (and its content clipped) from these numbers directly instead of from layout, so opening
/// and closing never re-lays out what's inside: the content sits at its final size and the
/// shape grows to reveal it.
struct IslandMetrics: VectorArithmetic, Equatable {
    var width: CGFloat = 0
    var height: CGFloat = 0
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = 0
    /// How far each side is pulled in from the symmetric width (short ear, tucked ear).
    var leadingTrim: CGFloat = 0
    var trailingTrim: CGFloat = 0

    /// The island within a container: centred horizontally, hanging from the top edge.
    func rect(in container: CGRect) -> CGRect {
        CGRect(x: container.midX - width / 2 + leadingTrim, y: container.minY,
               width: max(0, width - leadingTrim - trailingTrim), height: max(0, height))
    }

    static var zero: IslandMetrics { IslandMetrics() }

    static func + (lhs: IslandMetrics, rhs: IslandMetrics) -> IslandMetrics {
        IslandMetrics(width: lhs.width + rhs.width, height: lhs.height + rhs.height,
                      topRadius: lhs.topRadius + rhs.topRadius, bottomRadius: lhs.bottomRadius + rhs.bottomRadius,
                      leadingTrim: lhs.leadingTrim + rhs.leadingTrim, trailingTrim: lhs.trailingTrim + rhs.trailingTrim)
    }

    static func - (lhs: IslandMetrics, rhs: IslandMetrics) -> IslandMetrics {
        lhs + rhs.scaled(-1)
    }

    mutating func scale(by rhs: Double) {
        let factor = CGFloat(rhs)
        width *= factor
        height *= factor
        topRadius *= factor
        bottomRadius *= factor
        leadingTrim *= factor
        trailingTrim *= factor
    }

    private func scaled(_ factor: Double) -> IslandMetrics {
        var copy = self
        copy.scale(by: factor)
        return copy
    }

    var magnitudeSquared: Double {
        Double(width * width + height * height + topRadius * topRadius + bottomRadius * bottomRadius
               + leadingTrim * leadingTrim + trailingTrim * trailingTrim)
    }
}

/// The island: flat top that melts into the screen edge through concave "shoulders",
/// rounded bottom corners.
struct IslandShape: Shape {
    var metrics: IslandMetrics

    var animatableData: IslandMetrics {
        get { metrics }
        set { metrics = newValue }
    }

    func path(in rect: CGRect) -> Path {
        NotchPath.make(in: metrics.rect(in: rect), top: metrics.topRadius, bottom: metrics.bottomRadius, closed: true)
    }
}

enum NotchPath {
    static func make(in rect: CGRect, top: CGFloat, bottom: CGFloat, closed: Bool) -> Path {
        let shoulder = max(0, min(top, rect.width / 4, rect.height / 2))
        let corner = max(0, min(bottom, rect.height - shoulder, (rect.width - 2 * shoulder) / 2))
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - corner))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left + corner, y: rect.maxY), radius: corner)
        path.addLine(to: CGPoint(x: right - corner, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY - corner), radius: corner)
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        if closed { path.closeSubpath() }
        return path
    }
}

// MARK: - Burst

/// Confetti-ish ring of sparks that fires once when a turn completes.
struct BurstView: View {
    let start: Date
    let color: Color

    private let duration = 0.9

    var body: some View {
        FrameClock(active: Date().timeIntervalSince(start) < duration) { date in
            Canvas { canvas, size in
                let progress = date.timeIntervalSince(start) / duration
                guard progress >= 0, progress < 1 else { return }
                let eased = 1 - pow(1 - progress, 3)
                let fade = 1 - progress
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                let ringRadius = 5 + 16 * eased
                canvas.stroke(Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                                     width: ringRadius * 2, height: ringRadius * 2)),
                              with: .color(color.opacity(0.55 * fade)), lineWidth: 1.6 * fade)

                for index in 0..<10 {
                    let angle = Double(index) / 10 * 2 * .pi + 0.3
                    let distance = 7 + (index.isMultiple(of: 2) ? 19 : 14) * eased
                    let dot = (index.isMultiple(of: 2) ? 2.8 : 2.0) * fade
                    let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                    canvas.fill(Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                                with: .color((index.isMultiple(of: 3) ? Color.white : color).opacity(fade)))
                }
            }
        }
        .frame(width: 60, height: 60)
        .allowsHitTesting(false)
    }
}

// MARK: - Small pieces

struct DiffText: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(Fmt.count(added))")
                .foregroundStyle(Palette.add)
                .contentTransition(.numericText(value: Double(added)))
            Text("−\(Fmt.count(removed))")
                .foregroundStyle(Palette.remove)
                .contentTransition(.numericText(value: Double(removed)))
        }
        .monospacedDigit()
    }
}

struct CountBadge: View {
    let count: Int
    let tint: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(tint))
            .contentTransition(.numericText(value: Double(count)))
    }
}

struct LiveElapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Fmt.short(max(1, context.date.timeIntervalSince(since))))
        }
    }
}

// MARK: - App icons

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    /// Codex desktop ships inside the ChatGPT app under this bundle ID.
    static let codexBundleID = "com.openai.codex"
    private static let codexBundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBundleID)
        .flatMap(Bundle.init(url:))

    /// The Codex cloud on a dark tile, as Codex ships it for dark mode.
    static let codexIcon: NSImage? = codexBundle?.image(forResource: "icon-codex-dark-color") ?? icon(for: codexBundleID)

    /// The OpenAI knot, as Codex's menu bar template: an outline drawn for tiny sizes.
    static let codexKnot: CGImage? = {
        guard let image = codexBundle?.image(forResource: "chatgptTemplate") else { return nil }
        let best = image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
        return best?.cgImage
    }()

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

struct HostIcon: View {
    let bundleID: String?
    var agent: Agent = .claude
    let tint: Color
    let pulsing: Bool

    /// Codex sessions wear the Codex icon wherever they run; Claude sessions show their host app.
    private var image: NSImage? {
        agent == .codex ? (AppIcons.codexIcon ?? AppIcons.icon(for: bundleID)) : AppIcons.icon(for: bundleID)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Image(systemName: "terminal")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.dim)
                        )
                }
            }
            .frame(width: 28, height: 28)
            StatusDot(color: tint, pulsing: pulsing)
                .offset(x: 3, y: 3)
        }
    }
}

// MARK: - Effects

private struct JellyValues {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
}

private struct BlurFade: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 6 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }

    static var pop: AnyTransition {
        .scale(scale: 0.2).combined(with: .opacity)
    }
}

extension View {
    /// A squash-and-stretch hanging from the top edge, for "hey, look at me" moments.
    func jelly(trigger: Int) -> some View {
        keyframeAnimator(initialValue: JellyValues(), trigger: trigger) { content, value in
            content.scaleEffect(x: value.scaleX, y: value.scaleY, anchor: .top)
        } keyframes: { _ in
            KeyframeTrack(\.scaleX) {
                SpringKeyframe(1.07, duration: 0.14)
                SpringKeyframe(0.98, duration: 0.18)
                SpringKeyframe(1.0, duration: 0.35)
            }
            KeyframeTrack(\.scaleY) {
                SpringKeyframe(1.16, duration: 0.14)
                SpringKeyframe(0.95, duration: 0.18)
                SpringKeyframe(1.0, duration: 0.35)
            }
        }
    }
}
