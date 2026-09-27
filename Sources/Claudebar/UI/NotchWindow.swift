import AppKit
import SwiftUI

struct NotchGeometry: Equatable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    init(screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = screen.frame.width - left.width - right.width
            notchHeight = top
        } else {
            // No notch: float an island at the top of the menu bar instead.
            hasNotch = false
            notchWidth = 0
            notchHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 26)
        }
    }
}

@MainActor @Observable
final class NotchViewModel {
    let geometry: NotchGeometry
    var hovered = false
    /// An ear tucked into the notch because the pointer is close to it.
    var tuckLeft = false
    var tuckRight = false
    var pointerOnScreen = true
    /// The island's frame in window coordinates (top-left origin), for hit testing.
    @ObservationIgnored var shapeFrame: CGRect = .zero
    /// The ears' natural content widths, still known while they're tucked.
    @ObservationIgnored var leftEarWidth: CGFloat = 0
    @ObservationIgnored var rightEarWidth: CGFloat = 0

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    // Never steal keyboard focus from whatever you're typing in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One transparent, click-through panel per screen. It only starts taking mouse
/// events while the pointer is over the island, and hands them back when it leaves.
@MainActor
final class NotchWindowController {
    private static let windowSize = CGSize(width: 860, height: 760)
    /// How long the pointer has to rest on the notch before the panel opens, so passing
    /// through on the way somewhere else doesn't.
    private static let hoverIntent: TimeInterval = 0.3
    /// How far past an ear's outer end still counts as "on" it. Nothing below the bar counts:
    /// being under it shouldn't move it.
    private static let nearMargin = CGSize(width: 12, height: 0)

    let model: NotchViewModel
    private let screen: NSScreen
    private let panel: NotchPanel
    private let store: SessionStore
    private var enterWork: DispatchWorkItem?
    private var exitWork: DispatchWorkItem?
    private var untuckWork: [ReferenceWritableKeyPath<NotchViewModel, Bool>: DispatchWorkItem] = [:]
    private var pollTimer: Timer?
    private var pinnedUntil = Date.distantPast

    init(screen: NSScreen, store: SessionStore) {
        self.store = store
        self.screen = screen
        model = NotchViewModel(geometry: NotchGeometry(screen: screen))

        let width = min(Self.windowSize.width, screen.frame.width)
        let frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - Self.windowSize.height,
                           width: width, height: Self.windowSize.height)
        panel = NotchPanel(frame: frame)

        let host = NotchHostingView(rootView: NotchRootView(model: model, store: store))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        pollTimer?.invalidate()
        enterWork?.cancel()
        exitWork?.cancel()
        untuckWork.values.forEach { $0.cancel() }
        panel.orderOut(nil)
        panel.close()
    }

    /// Opens the panel without the pointer, e.g. from `curl localhost:47823/peek`.
    func peek(for seconds: TimeInterval) {
        pinnedUntil = Date().addingTimeInterval(seconds)
        setHovered(true)
        _ = schedule(after: seconds + 0.05) { $0.mouseMoved() }
    }

    func mouseMoved() {
        let pointer = NSEvent.mouseLocation
        let onScreen = NSScreen.screens.count == 1 || screen.frame.contains(pointer)
        if model.pointerOnScreen != onScreen { model.pointerOnScreen = onScreen }

        if Date() < pinnedUntil { return }

        if model.hovered {
            if openRect().contains(pointer) {
                exitWork?.cancel()
                exitWork = nil
            } else if exitWork == nil {
                exitWork = schedule(after: 0.3) { $0.setHovered(false) }
            }
            return
        }

        // Only the middle opens the panel. Mid-drag (a window, a selection) never does.
        if triggerRect().contains(pointer) {
            guard enterWork == nil, NSEvent.pressedMouseButtons == 0 else { return }
            enterWork = schedule(after: Self.hoverIntent) { $0.setHovered(true) }
            return
        }
        enterWork?.cancel()
        enterWork = nil

        // Near an ear, that ear tucks into the notch so the menu bar under it is reachable.
        let zones = nearZones()
        setTucked(\.tuckLeft, near: zones.left.contains(pointer))
        setTucked(\.tuckRight, near: zones.right.contains(pointer))
    }

    /// Tucks a side straight away; brings it back out a moment after the pointer leaves.
    private func setTucked(_ side: ReferenceWritableKeyPath<NotchViewModel, Bool>, near: Bool) {
        if near {
            untuckWork.removeValue(forKey: side)?.cancel()
            if !model[keyPath: side] { model[keyPath: side] = true }
        } else if model[keyPath: side], untuckWork[side] == nil {
            untuckWork[side] = schedule(after: 0.25) { controller in
                controller.untuckWork[side] = nil
                controller.model[keyPath: side] = false
            }
        }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor (NotchWindowController) -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private func setHovered(_ hovered: Bool) {
        enterWork = nil
        exitWork = nil
        guard model.hovered != hovered else { return }
        model.hovered = hovered
        panel.ignoresMouseEvents = !hovered

        // Mouse-moved events stop arriving reliably once the pointer is over our own
        // non-key panel, so poll while expanded to notice when it leaves.
        pollTimer?.invalidate()
        pollTimer = nil
        if hovered {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    /// The notch itself (on a notchless display, the middle of the island): the only place that
    /// opens the panel.
    private func triggerRect() -> CGRect {
        let geometry = model.geometry
        // A floating island on a notchless screen is invisible while idle; don't let it catch the pointer.
        guard geometry.hasNotch || store.presentation.mode != .idle else { return .zero }
        let width = NotchMetrics.triggerWidth(geometry)
        // Reach above the screen's top edge so the topmost pixel row still counts.
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - geometry.notchHeight,
                      width: width, height: geometry.notchHeight + 2)
    }

    /// The areas around each ear that count as "close", from its outer end in to where the
    /// notch trigger starts. Built from the ears' natural widths, so tucking an ear doesn't
    /// take the pointer out of range and bounce it straight back out.
    private func nearZones() -> (left: CGRect, right: CGRect) {
        guard store.presentation.mode != .idle else { return (.zero, .zero) }
        let geometry = model.geometry
        let margin = Self.nearMargin
        let midX = screen.frame.midX
        let reach = NotchMetrics.openGap(geometry) / 2 + NotchMetrics.collapsedInset + margin.width
        let inner = NotchMetrics.triggerWidth(geometry) / 2
        let y = screen.frame.maxY - geometry.notchHeight - margin.height
        let height = geometry.notchHeight + margin.height + 2
        let leftOuter = midX - reach - model.leftEarWidth
        let rightOuter = midX + reach + model.rightEarWidth
        return (CGRect(x: leftOuter, y: y, width: max(0, midX - inner - leftOuter), height: height),
                CGRect(x: midX + inner, y: y, width: max(0, rightOuter - midX - inner), height: height))
    }

    /// The open panel plus a little slack, so it doesn't flicker shut at the edges.
    private func openRect() -> CGRect {
        screenRect(model.shapeFrame).insetBy(dx: -4, dy: -4)
    }

    /// A frame in the window's top-left coordinates, in screen coordinates.
    private func screenRect(_ frame: CGRect) -> CGRect {
        let window = panel.frame
        return CGRect(x: window.minX + frame.minX, y: window.maxY - frame.maxY, width: frame.width, height: frame.height)
    }
}
