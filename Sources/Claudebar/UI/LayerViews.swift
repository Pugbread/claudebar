import AppKit
import QuartzCore
import SwiftUI

// The bar's looping animations (spark, glow, level meter) can run for hours while
// Claude works. Redrawing them from SwiftUI costs main-thread time on every frame, so
// they're built from Core Animation layers instead: once an animation is added, the
// render server drives it and this process does nothing until the state changes.

/// Layer-hosting view with a top-left origin, transparent to clicks so SwiftUI
/// gestures on the surrounding views keep working.
class LayerHostingView: NSView {
    let root = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = root
        wantsLayer = true
        root.masksToBounds = false
        root.isGeometryFlipped = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // AppKit keeps the root layer's geometryFlipped in sync with this, so it has to
    // agree with the top-left origin the paths are built in.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        func apply(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(apply)
            layer.mask.map(apply)
        }
        apply(root)
    }
}

extension CABasicAnimation {
    static func spin(duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    static func oscillate(_ keyPath: String, from: Double, to: Double, duration: CFTimeInterval,
                          offset: CFTimeInterval = 0) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timeOffset = offset
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        return animation
    }
}

private func withoutActions(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
}

// MARK: - Spark

/// The status glyph. Idle it sits still; thinking it turns slowly and breathes; busy it
/// spins up; waiting it stops and pulses. Claude gets a ragged 12-ray asterisk; Codex gets
/// the OpenAI knot (Codex's own menu bar outline), or an 8-point star if Codex isn't installed.
struct SparkView: NSViewRepresentable {
    enum Style: Equatable { case idle, thinking, busy, waiting }

    let color: Color
    let style: Style
    var agent: Agent = .claude

    func makeNSView(context: Context) -> SparkLayerView {
        SparkLayerView(frame: .zero)
    }

    func updateNSView(_ view: SparkLayerView, context: Context) {
        view.configure(color: NSColor(color), style: style, agent: agent, animated: context.environment.motionEnabled)
    }
}

final class SparkLayerView: LayerHostingView {
    private static func rays(for agent: Agent) -> [CGFloat] {
        switch agent {
        case .claude: [1.0, 0.64, 0.9, 0.7, 0.97, 0.6, 0.86, 0.68, 0.94, 0.62, 0.88, 0.74]
        case .codex: [1.0, 0.5, 1.0, 0.5, 1.0, 0.5, 1.0, 0.5]
        }
    }

    /// Rotates, breathes and glows; holds whichever mark is showing.
    private let glyph = CALayer()
    private let spark = CAShapeLayer()
    /// Solid colour cut to the knot's outline by its template image.
    private let knot = CALayer()
    private let knotMask = CALayer()
    private var rays = SparkLayerView.rays(for: .claude)
    private var agent: Agent?
    private var current: (style: SparkView.Style, animated: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.shadowOffset = .zero
        glyph.shadowRadius = 3
        spark.fillColor = nil
        spark.lineCap = .round
        knotMask.contentsGravity = .resizeAspect
        knot.mask = knotMask
        knot.isHidden = true
        glyph.addSublayer(spark)
        glyph.addSublayer(knot)
        root.addSublayer(glyph)
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let lineWidth = max(1.4, side * 0.1)
        let radius = side / 2 - lineWidth / 2
        let path = CGMutablePath()
        for (index, length) in rays.enumerated() {
            let angle = CGFloat(index) / CGFloat(rays.count) * 2 * .pi
            let (dx, dy) = (cos(angle), sin(angle))
            path.move(to: CGPoint(x: side / 2 + dx * radius * 0.16, y: side / 2 + dy * radius * 0.16))
            path.addLine(to: CGPoint(x: side / 2 + dx * radius * length, y: side / 2 + dy * radius * length))
        }
        withoutActions {
            glyph.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
            spark.frame = glyph.bounds
            spark.lineWidth = lineWidth
            spark.path = path
            knot.frame = glyph.bounds
            knotMask.frame = knot.bounds
        }
    }

    func configure(color: NSColor, style: SparkView.Style, agent: Agent, animated: Bool) {
        if agent != self.agent {
            self.agent = agent
            let knotImage = agent == .codex ? AppIcons.codexKnot : nil
            knotMask.contents = knotImage
            knot.isHidden = knotImage == nil
            spark.isHidden = knotImage != nil
            rays = Self.rays(for: agent)
            needsLayout = true
        }
        spark.strokeColor = color.cgColor
        knot.backgroundColor = color.cgColor
        glyph.shadowColor = color.cgColor
        glyph.shadowOpacity = style == .idle ? 0 : 0.8
        guard current?.style != style || current?.animated != animated else { return }
        current = (style, animated)

        glyph.removeAllAnimations()
        guard animated else { return }
        switch style {
        case .idle:
            break
        case .thinking:
            glyph.add(CABasicAnimation.spin(duration: 7), forKey: "spin")
            glyph.add(CABasicAnimation.oscillate("transform.scale", from: 0.9, to: 1.04, duration: 1.1), forKey: "breathe")
        case .busy:
            glyph.add(CABasicAnimation.spin(duration: 2.4), forKey: "spin")
            glyph.add(CABasicAnimation.oscillate("transform.scale", from: 0.86, to: 1.04, duration: 0.42), forKey: "breathe")
        case .waiting:
            glyph.add(CABasicAnimation.oscillate("transform.scale", from: 0.74, to: 1.0, duration: 0.65), forKey: "breathe")
        }
    }
}

// MARK: - Glow

/// A conic gradient spinning around the island's edge, plus a soft copy for bloom.
struct GlowOutline: NSViewRepresentable {
    let bar: BarPresentation
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    func makeNSView(context: Context) -> GlowLayerView {
        GlowLayerView(frame: .zero)
    }

    func updateNSView(_ view: GlowLayerView, context: Context) {
        let colors = (bar.glow + [bar.glow.first ?? Palette.slate]).map { NSColor($0).cgColor }
        view.configure(colors: colors, mode: bar.mode, since: bar.modeSince,
                       topRadius: topRadius, bottomRadius: bottomRadius,
                       animated: context.environment.motionEnabled)
    }
}

final class GlowLayerView: LayerHostingView {
    private let strength = CALayer()
    private let bloom = GradientRing(lineWidth: 6, softness: 7)
    private let rim = GradientRing(lineWidth: 1.4, softness: 0)
    private var radii: (top: CGFloat, bottom: CGFloat) = (0, 0)
    private var currentKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        root.addSublayer(strength)
        bloom.holder.opacity = 0.8
        strength.addSublayer(bloom.holder)
        strength.addSublayer(rim.holder)
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    private func updateGeometry() {
        let path = NotchPath.make(in: bounds, top: radii.top, bottom: radii.bottom, closed: false).cgPath
        withoutActions {
            strength.frame = bounds
            bloom.update(bounds: bounds, path: path)
            rim.update(bounds: bounds, path: path)
        }
    }

    func configure(colors: [CGColor], mode: BarMode, since: Date, topRadius: CGFloat, bottomRadius: CGFloat, animated: Bool) {
        bloom.gradient.colors = colors
        rim.gradient.colors = colors
        if radii != (topRadius, bottomRadius) {
            radii = (topRadius, bottomRadius)
            updateGeometry()
        }

        let key = "\(mode)|\(since.timeIntervalSinceReferenceDate)|\(animated)"
        guard key != currentKey else { return }
        currentKey = key

        bloom.gradient.removeAllAnimations()
        rim.gradient.removeAllAnimations()
        strength.removeAllAnimations()
        strength.opacity = Float(Self.restingStrength(mode))
        guard animated else { return }

        let degreesPerSecond: Double = switch mode {
        case .done: 160
        case .compacting: 110
        case .waiting: 30
        default: 60
        }
        let spin = CABasicAnimation.spin(duration: 360 / degreesPerSecond)
        bloom.gradient.add(spin, forKey: "spin")
        rim.gradient.add(spin, forKey: "spin")

        switch mode {
        case .working:
            strength.add(CABasicAnimation.oscillate("opacity", from: 0.42, to: 0.62, duration: 1.9), forKey: "strength")
        case .waiting:
            strength.add(CABasicAnimation.oscillate("opacity", from: 0.4, to: 1.0, duration: 0.7), forKey: "strength")
        case .done:
            fade(from: 1, over: 2.5, since: since)
        case .failed:
            fade(from: 1, over: 3, since: since)
        default:
            break
        }
    }

    /// Fades from `from` down to the resting strength, picking up partway through if the
    /// view appeared after the state change.
    private func fade(from start: Double, over duration: Double, since: Date) {
        let elapsed = Date().timeIntervalSince(since)
        let end = Double(strength.opacity)
        guard elapsed < duration else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start + (end - start) * elapsed / duration
        animation.toValue = end
        animation.duration = duration - elapsed
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        strength.add(animation, forKey: "strength")
    }

    private static func restingStrength(_ mode: BarMode) -> Double {
        switch mode {
        case .idle: 0
        case .working: 0.5
        case .compacting: 0.75
        case .waiting: 0.7
        case .done: 0.25
        case .failed, .interrupted: 0.35
        }
    }
}

/// A conic gradient spinning underneath a stroke-shaped mask. The mask lives on a
/// holder layer that doesn't rotate, so only the colours move.
private final class GradientRing {
    let holder = CALayer()
    let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()

    init(lineWidth: CGFloat, softness: CGFloat) {
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = lineWidth
        mask.lineCap = .round
        if softness > 0 {
            mask.shadowColor = NSColor.black.cgColor
            mask.shadowOpacity = 1
            mask.shadowRadius = softness
            mask.shadowOffset = .zero
        }
        holder.mask = mask
        holder.addSublayer(gradient)
    }

    func update(bounds: CGRect, path: CGPath) {
        holder.frame = bounds
        mask.frame = bounds
        mask.path = path
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - Level meter

/// Four little bars that dance while Claude works, breathe while it waits, and
/// settle when it's done.
struct MiniMeter: NSViewRepresentable {
    let tint: Color
    let mode: BarMode

    func makeNSView(context: Context) -> MeterLayerView {
        MeterLayerView(frame: .zero)
    }

    func updateNSView(_ view: MeterLayerView, context: Context) {
        view.configure(tint: NSColor(tint), mode: mode, animated: context.environment.motionEnabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeterLayerView, context: Context) -> CGSize? {
        MeterLayerView.size
    }
}

final class MeterLayerView: LayerHostingView {
    static let size = CGSize(width: 4 * barWidth + 3 * spacing, height: 14)
    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 2

    private let bars = (0..<4).map { _ in CALayer() }
    private var restingHeights: [CGFloat] = [3, 3, 3, 3]
    private var current: (mode: BarMode, animated: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for bar in bars {
            bar.cornerRadius = Self.barWidth / 2
            bar.shadowOffset = .zero
            bar.shadowRadius = 2
            bar.shadowOpacity = 0.6
            root.addSublayer(bar)
        }
    }

    override func layout() {
        super.layout()
        withoutActions {
            for (index, bar) in bars.enumerated() {
                bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: restingHeights[index])
                bar.position = CGPoint(x: CGFloat(index) * (Self.barWidth + Self.spacing) + Self.barWidth / 2,
                                       y: bounds.midY)
            }
        }
    }

    func configure(tint: NSColor, mode: BarMode, animated: Bool) {
        for bar in bars {
            bar.backgroundColor = tint.cgColor
            bar.shadowColor = tint.cgColor
        }
        guard current?.mode != mode || current?.animated != animated else { return }
        current = (mode, animated)

        restingHeights = switch mode {
        case .done: [9, 12, 7, 10]
        case .working, .compacting, .waiting: [6, 10, 5, 8]
        case .failed, .interrupted, .idle: [3, 3, 3, 3]
        }
        needsLayout = true
        bars.forEach { $0.removeAllAnimations() }
        guard animated else { return }

        let height = "bounds.size.height"
        for (index, bar) in bars.enumerated() {
            switch mode {
            case .working:
                let durations = [0.42, 0.56, 0.36, 0.61]
                bar.add(CABasicAnimation.oscillate(height, from: 3, to: 14, duration: durations[index], offset: Double(index) * 0.13),
                        forKey: "level")
            case .compacting:
                bar.add(CABasicAnimation.oscillate(height, from: 3, to: 14, duration: 0.55, offset: 0.55 - Double(index) * 0.12),
                        forKey: "level")
            case .waiting:
                bar.add(CABasicAnimation.oscillate(height, from: 4, to: 12, duration: 0.7), forKey: "level")
            default:
                break
            }
        }
    }
}
