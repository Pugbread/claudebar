import AVKit
import QuickLookThumbnailing
import SwiftUI

/// The row of images and videos agents touched, at the top of the expanded panel.
struct MediaShelf: View {
    let store: SessionStore
    @Binding var previewing: MediaItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("MEDIA")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                Text("\(store.media.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Spacer()
                Button("Clear") {
                    previewing = nil
                    store.clearMedia()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.dim)
            }
            .foregroundStyle(Palette.faint)

            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy: only the thumbnails in view get built when the panel opens.
                LazyHStack(spacing: 8) {
                    ForEach(store.media) { item in
                        MediaThumb(item: item, highlighted: previewing == item,
                                   onOpen: { NSWorkspace.shared.open(item.url) },
                                   onDragOut: { previewing = nil })
                            .onHoverAlways { inside in
                                if inside {
                                    previewing = item
                                } else if previewing == item {
                                    previewing = nil
                                }
                            }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(item.url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Divider()
                                Button("Remove from shelf") {
                                    if previewing == item { previewing = nil }
                                    store.removeMedia(item)
                                }
                            }
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 1)
            }
            // A lazy row can't report its height up front; without this it fills the panel.
            .frame(height: 64)
        }
        .padding(.horizontal, 6)
    }
}

private struct MediaThumb: View {
    let item: MediaItem
    let highlighted: Bool
    let onOpen: () -> Void
    let onDragOut: () -> Void
    @State private var image: CGImage?
    @State private var duration: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06))
            if let image {
                PictureLayer(image: image, fill: true, cornerRadius: 9)
                    .frame(width: 84, height: 58)
            }
            if item.kind == .video {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 6.5, weight: .bold))
                    if let duration { Text(duration) }
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .padding(4)
            }
        }
        .frame(width: 84, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(highlighted ? 0.75 : 0.1), lineWidth: highlighted ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            // Whose session touched it.
            Circle().fill(item.agent.accent).frame(width: 5, height: 5).padding(5)
        }
        .overlay(FileDragSource(url: item.url, picture: image, cornerRadius: 9, onClick: onOpen, onDragStart: onDragOut))
        .scaleEffect(highlighted ? 1.05 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: highlighted)
        .task(id: item.path) {
            image = await MediaThumbnails.shared.image(for: item.url, maxSide: 200)
            if item.kind == .video { duration = await MediaThumbnails.shared.duration(of: item.url) }
        }
    }
}

/// The big look at a shelf item while its thumbnail is hovered: images fit to the card,
/// videos play muted on a loop.
struct MediaPreview: View {
    let item: MediaItem
    @State private var image: CGImage?
    @State private var detail: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if item.kind == .video {
                    LoopingVideo(url: item.url)
                } else if let image {
                    PictureLayer(image: image, fill: false)
                }
            }
            .frame(height: 300)

            HStack(spacing: 8) {
                Image(systemName: item.kind == .video ? "film" : "photo")
                    .foregroundStyle(item.agent.accent)
                Text(item.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.action) · \(item.session)")
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.faint)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
        )
        .task(id: item.path) {
            if item.kind == .image {
                image = await MediaThumbnails.shared.image(for: item.url, maxSide: 1100)
                detail = MediaThumbnails.pixelSize(of: item.url)
            } else {
                detail = await MediaThumbnails.shared.duration(of: item.url)
            }
        }
    }
}

/// Thumbnails and video durations, generated off the main thread by Quick Look and cached.
@MainActor
final class MediaThumbnails {
    static let shared = MediaThumbnails()
    private var images: [String: CGImage] = [:]

    func image(for url: URL, maxSide: CGFloat) async -> CGImage? {
        let modified = MediaScanner.modificationDate(of: url.path)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(Int(maxSide))|\(modified)"
        if let cached = images[key] { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxSide, height: maxSide),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let pixels = representation.cgImage
        if images.count > 80 { images.removeAll() }
        images[key] = pixels
        return pixels
    }

    func duration(of url: URL) async -> String? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return Fmt.clock(duration.seconds)
    }

    static func pixelSize(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width)×\(height)"
    }
}

/// A picture drawn by Core Animation and scaled on the GPU. SwiftUI's own image drawing
/// cut these off: Quick Look's Retina image came out as its top-left quarter, and large images
/// (drawn in a scaled layer of their own) had the card's rounded clip land on one corner.
private struct PictureLayer: NSViewRepresentable {
    let image: CGImage
    /// Fill the frame and crop the overflow (thumbnails), or fit inside it (the preview).
    let fill: Bool
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> PictureView {
        PictureView(frame: .zero)
    }

    func updateNSView(_ view: PictureView, context: Context) {
        view.show(image, fill: fill, cornerRadius: cornerRadius)
    }

    final class PictureView: NSView {
        private var shown: CGImage?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            layer?.masksToBounds = true
            layer?.minificationFilter = .trilinear
            layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func show(_ image: CGImage, fill: Bool, cornerRadius: CGFloat) {
            guard let layer else { return }
            if shown !== image {
                shown = image
                layer.contents = image
            }
            layer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
        }

        // Clicks and hovers belong to the thumbnail around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Clicking a thumbnail opens its file; dragging it drops the file into another app (Finder,
/// a chat, an editor). An AppKit drag, so the file goes out as a plain file URL every app takes,
/// and only as a copy: Finder never moves it out of the agent's project.
private struct FileDragSource: NSViewRepresentable {
    let url: URL
    /// The thumbnail, lifted as the drag image.
    let picture: CGImage?
    let cornerRadius: CGFloat
    let onClick: () -> Void
    let onDragStart: () -> Void

    func makeNSView(context: Context) -> DragView {
        DragView(frame: .zero)
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.url = url
        view.picture = picture
        view.cornerRadius = cornerRadius
        view.onClick = onClick
        view.onDragStart = onDragStart
    }

    final class DragView: NSView, NSDraggingSource {
        /// The view a drag started from, kept alive until it lands: the panel closes when the
        /// pointer leaves it, taking the thumbnail with it.
        private static var dragging: DragView?
        private static let dragThreshold: CGFloat = 4

        var url: URL?
        var picture: CGImage?
        var cornerRadius: CGFloat = 0
        var onClick: (() -> Void)?
        var onDragStart: (() -> Void)?
        private var mouseDownAt: NSPoint?

        // The panel is never key, so the first click has to count.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Only plain left clicks land here. Hovers, scrolling and the context menu (right or
        // control click) stay with the SwiftUI thumbnail underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
                  !event.modifierFlags.contains(.control) else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownAt = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownAt, let url else { return }
            let point = event.locationInWindow
            guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
            mouseDownAt = nil

            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let (frame, image) = dragImage(for: url)
            item.setDraggingFrame(frame, contents: image)
            Self.dragging = self
            beginDraggingSession(with: [item], event: event, source: self)
            onDragStart?()
        }

        override func mouseUp(with event: NSEvent) {
            if mouseDownAt != nil { onClick?() }
            mouseDownAt = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            Self.dragging = nil
        }

        /// The thumbnail as it looks on the shelf, or the file's icon at its own square size
        /// while the thumbnail is still loading.
        private func dragImage(for url: URL) -> (NSRect, NSImage) {
            guard let picture else {
                let side = min(bounds.width, bounds.height)
                let frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
                return (frame, NSWorkspace.shared.icon(forFile: url.path))
            }
            let radius = cornerRadius
            let image = NSImage(size: bounds.size, flipped: false) { rect in
                let scale = max(rect.width / CGFloat(picture.width), rect.height / CGFloat(picture.height))
                let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
                NSGraphicsContext.current?.cgContext.draw(
                    picture, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                        width: size.width, height: size.height))
                return true
            }
            return (bounds, image)
        }
    }
}

/// A muted video on a loop, with no controls.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        coordinator.looper = nil
    }
}

// MARK: - Hover that works in a background window

/// SwiftUI's onHover can go quiet in a panel that never becomes key; a tracking area that's
/// active regardless of focus doesn't.
private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func onHoverAlways(_ action: @escaping (Bool) -> Void) -> some View {
        background(HoverTracker(onChange: action))
    }
}
