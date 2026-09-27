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
                HStack(spacing: 8) {
                    ForEach(store.media) { item in
                        MediaThumb(item: item, highlighted: previewing == item)
                            .onHoverAlways { inside in
                                if inside {
                                    previewing = item
                                } else if previewing == item {
                                    previewing = nil
                                }
                            }
                            .onTapGesture { NSWorkspace.shared.open(item.url) }
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
        }
        .padding(.horizontal, 6)
    }
}

private struct MediaThumb: View {
    let item: MediaItem
    let highlighted: Bool
    @State private var image: NSImage?
    @State private var duration: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
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
    @State private var image: NSImage?
    @State private var detail: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if item.kind == .video {
                    LoopingVideo(url: item.url)
                } else if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
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
        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
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
    private var images: [String: NSImage] = [:]

    func image(for url: URL, maxSide: CGFloat) async -> NSImage? {
        let modified = MediaScanner.modificationDate(of: url.path)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(Int(maxSide))|\(modified)"
        if let cached = images[key] { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxSide, height: maxSide),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        if images.count > 80 { images.removeAll() }
        images[key] = representation.nsImage
        return representation.nsImage
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
