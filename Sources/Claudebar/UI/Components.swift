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

/// The island: flat top that melts into the screen edge through concave "shoulders",
/// rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { (topRadius, bottomRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        NotchPath.make(in: rect, top: topRadius, bottom: bottomRadius, closed: true)
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

struct Spinner: View {
    let color: Color

    var body: some View {
        FrameClock(active: true) { date in
            let degrees = (date.timeIntervalSinceReferenceDate * 400).truncatingRemainder(dividingBy: 360)
            Circle()
                .trim(from: 0.12, to: 0.78)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(degrees))
        }
        .frame(width: 10, height: 10)
    }
}

struct StatusDot: View {
    let color: Color
    let pulsing: Bool

    var body: some View {
        FrameClock(active: pulsing) { date in
            let progress = pulsing ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 : 1
            ZStack {
                Circle()
                    .stroke(color.opacity(0.8 * (1 - progress)), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(1 + progress * 1.3)
                Circle().fill(Color.black).frame(width: 12, height: 12)
                Circle().fill(color).frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
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

struct Shimmer: ViewModifier {
    let base: Color
    let highlight: Color

    func body(content: Content) -> some View {
        FrameClock(active: true) { date in
            let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            let phase = cycle * 1.6 - 0.3
            content.foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: base, location: 0),
                        .init(color: base, location: clamp(phase - 0.2)),
                        .init(color: highlight, location: clamp(phase)),
                        .init(color: base, location: clamp(phase + 0.2)),
                        .init(color: base, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

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
    func shimmer(base: Color, highlight: Color = .white) -> some View {
        modifier(Shimmer(base: base, highlight: highlight))
    }

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
