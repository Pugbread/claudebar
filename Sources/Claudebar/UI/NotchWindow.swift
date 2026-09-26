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
    var pointerOnScreen = true
    /// The island's frame in window coordinates (top-left origin), for hit testing.
    @ObservationIgnored var shapeFrame: CGRect = .zero

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
    private static let windowSize = CGSize(width: 860, height: 560)

    let model: NotchViewModel
    private let screen: NSScreen
    private let panel: NotchPanel
    private let store: SessionStore
    private var enterWork: DispatchWorkItem?
    private var exitWork: DispatchWorkItem?
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
        if hotRect().contains(pointer) {
            exitWork?.cancel()
            exitWork = nil
            guard !model.hovered, enterWork == nil else { return }
            enterWork = schedule(after: 0.08) { $0.setHovered(true) }
        } else {
            enterWork?.cancel()
            enterWork = nil
            guard model.hovered, exitWork == nil else { return }
            exitWork = schedule(after: 0.3) { $0.setHovered(false) }
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

    private func hotRect() -> CGRect {
        let frame = model.shapeFrame
        // A floating island on a notchless screen is invisible while idle; don't let it catch the pointer.
        guard frame.width > 1, model.geometry.hasNotch || model.hovered || store.presentation.mode != .idle else { return .zero }
        let window = panel.frame
        return CGRect(x: window.minX + frame.minX, y: window.maxY - frame.maxY, width: frame.width, height: frame.height)
            .insetBy(dx: -4, dy: -4)
    }
}
