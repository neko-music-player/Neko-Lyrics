import AppKit
import AVFoundation
import SwiftUI

/// Never takes focus, never receives clicks.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Two click-through, borderless, full-screen windows:
///  - top: above every app (and, via LockScreenLayer, above the lock screen). Draws the edge light, and
///    the whole lyrics scene while the Mac is locked / previewing.
///  - desk: sits on the desktop, behind your apps and the player. Draws the lyrics scene on the desktop.
@MainActor
final class OverlayController {
    private var top: OverlayWindow?
    private var desk: OverlayWindow?
    private var widget: NSPanel?
    private var lockAttached = false
    private unowned let engine: Engine

    init(engine: Engine) { self.engine = engine }

    private static var desktopLevel: Int { Int(CGWindowLevelForKey(.desktopWindow)) }

    private func makeWindow(on screen: NSScreen, role: OverlayRole) -> OverlayWindow {
        let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.canBecomeVisibleWithoutLogin = true
        w.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        w.level = role == .top ? NSWindow.Level(rawValue: Int(Int32.max - 2))
                               : NSWindow.Level(rawValue: Self.desktopLevel + 2)
        w.contentView = NSHostingView(rootView: LyricsOverlayView(engine: engine, role: role))
        return w
    }

    func show() {
        // On the lock screen NSScreen.main can be nil, so fall back to any screen.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            LockScreenLayer.log("show(): no screen")
            return
        }
        let topFull: Bool = engine.isLocked || engine.lyricsAboveApps || engine.previewing
        // Windows moved above the lock screen lose their "every desktop" membership; rebuild them after unlocking.
        if !engine.isLocked && lockAttached {
            top?.close(); top = nil
            widget?.close(); widget = nil
            lockAttached = false
        }

        if topFull || engine.edgeLight {
            if top == nil { top = makeWindow(on: screen, role: .top) }
            // Above every app, but below the menu bar and its pop-ups, so the menu-bar icon and settings stay usable.
            // Only the lock screen needs the very top.
            top?.level = engine.isLocked ? NSWindow.Level(rawValue: Int(Int32.max - 2))
                                         : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) - 1)
            if top?.frame != screen.frame { top?.setFrame(screen.frame, display: true) }
            if top?.isVisible != true { top?.orderFrontRegardless() }
            if engine.isLocked, let w = top { LockScreenLayer.shared.attach(w); lockAttached = true }
        } else {
            top?.orderOut(nil)
        }

        // The desktop layer also draws the chosen Background behind the player (the player itself stays see-through).
        let wantsDesk: Bool = !topFull && ((engine.lyricsEnabled && !engine.lines.isEmpty) || engine.background != .transparent || (engine.artwork.isCard && engine.track != nil))
        if wantsDesk {
            if desk == nil { desk = makeWindow(on: screen, role: .desk) }
            if desk?.frame != screen.frame { desk?.setFrame(screen.frame, display: true) }
            if desk?.isVisible != true { desk?.orderFront(nil) }
        } else {
            desk?.orderOut(nil)
        }
        showWidget(on: screen)
        LockScreenLayer.log("show(): locked=\(engine.isLocked) topFull=\(topFull) edge=\(engine.edgeLight) top=\(top?.windowNumber ?? -1) desk=\(wantsDesk)")
    }

    func hide() {
        top?.orderOut(nil)
        desk?.orderOut(nil)
        widget?.orderOut(nil)
    }

    /// The same glass player bar as the desktop player, on the lock screen. Unlike the lyrics windows it
    /// takes clicks, but never keyboard focus, so it can't capture anything typed (like a password).
    private func showWidget(on screen: NSScreen) {
        // Only belongs on the lock screen (or in a preview).
        guard engine.showWidget, !engine.showLockPlayer, engine.isLocked || engine.previewing else { widget?.orderOut(nil); return }
        let size = NSSize(width: 720, height: 70)
        if widget == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isReleasedWhenClosed = false
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.canBecomeVisibleWithoutLogin = true
            p.level = NSWindow.Level(rawValue: Int(Int32.max - 1))
            p.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
            let host = FirstMouseHostingView(rootView: MusicWidgetView(engine: engine))
            host.frame = NSRect(origin: .zero, size: size)
            p.contentView = host
            widget = p
        }
        let f = screen.frame
        let y: CGFloat = f.minY + f.height * CGFloat(engine.widgetFraction)
        let wf = NSRect(x: f.midX - size.width / 2, y: y, width: size.width, height: size.height)
        if widget?.frame != wf { widget?.setFrame(wf, display: true) }
        if widget?.isVisible != true { widget?.orderFrontRegardless() }
        if engine.isLocked, let w = widget { LockScreenLayer.shared.attach(w); lockAttached = true }
        engine.library.refreshState()
    }
}

enum OverlayRole { case top, desk }

struct LyricsOverlayView: View {
    @ObservedObject var engine: Engine
    let role: OverlayRole

    /// The top window carries the whole scene while locked; otherwise only the edge light.
    private var topFull: Bool { engine.isLocked || engine.lyricsAboveApps || engine.previewing }

    /// Lyrics are drawn full screen unless the player is showing (it hosts them itself, so never both).
    private var showsLyrics: Bool {
        engine.lyricsEnabled && !engine.playerHostsLyrics
    }

    var body: some View {
        ZStack {
            if role == .desk || topFull {
                // Lyrics scene: 30 fps so words light at the right moment.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    scene(t: engine.currentTime, palette: engine.palette,
                          clock: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            if role == .top && engine.edgeLight {
                // The edge light is slow and soft, so it gets its own, lighter timeline.
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                    EdgeLightView(colors: edgeColors(engine.palette),
                                  clock: timeline.date.timeIntervalSinceReferenceDate,
                                  kick: engine.isPlaying ? engine.kick(at: engine.currentTime) : 0,
                                  thickness: engine.edgeThickness, glow: engine.edgeGlow, radius: engine.edgeRadius)
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func scene(t: TimeInterval, palette: Palette, clock: Double) -> some View {
        ZStack {
            BackdropView(mode: engine.background, palette: palette, image: engine.albumSmall ?? engine.albumImage, clock: clock,
                         sharp: engine.albumImage, sharpness: engine.coverSharpness,
                         zoom: engine.coverZoom, motion: engine.coverMotion)
            if engine.background == .fullArtwork {
                ArtworkFill(image: engine.albumImage, video: engine.videoURL, clock: clock)
            }
            GeometryReader { g in
                if showsLyrics && engine.lines.isEmpty, let tr = engine.track {
                    // No lyrics for this song: the cover in the middle with the name under it, nothing else.
                    let side: CGFloat = min(g.size.height * 0.5, g.size.width * 0.3)
                    VStack(spacing: 18) {
                        if engine.artwork.isCard {
                            ArtworkCard(image: engine.albumImage, video: engine.videoURL,
                                        animated: engine.artwork == .animated, glow: palette.highlight, clock: clock)
                                .frame(width: side, height: side)
                        }
                        VStack(spacing: 4) {
                            Text(tr.title).font(.system(size: 30, weight: .semibold)).lineLimit(2)
                            Text(tr.artist).font(.system(size: 19)).opacity(0.7).lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.6), radius: 8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: g.size.width * 0.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        if engine.artwork.isCard && !engine.playerHostsLyrics {     // the player carries its own card
                            ArtworkCard(image: engine.albumImage, video: engine.videoURL,
                                        animated: engine.artwork == .animated, glow: palette.highlight, clock: clock)
                                .frame(width: g.size.width * 0.32, height: g.size.height)
                        }
                        if showsLyrics {
                            LyricsStyleHost(engine: engine, t: t, palette: palette, clock: clock)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .shadow(color: Color.black.opacity(engine.background == .transparent ? 0.65 : 0), radius: 8)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// The edge light always follows the album cover when there is one, whatever Auto Sync says.
    private func edgeColors(_ p: Palette) -> [Color] {
        let raw: [Color] = engine.albumPalette.map { [$0.highlight, $0.backdropA, $0.lyric, $0.backdropB] }
            ?? (p.isAuto ? [p.highlight, p.backdropA, p.lyric, p.backdropB] : [p.highlight, p.lyric, p.highlight])
        // Grey / black / white parts of a cover have no real colour; using them makes the glow turn red.
        let coloured: [Color] = raw.filter { $0.saturation > 0.2 }
        return coloured.isEmpty ? [p.highlight] : coloured
    }
}

/// The chosen lyrics style, drawn into whatever space it is given (full screen or the player's center).
struct LyricsStyleHost: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette
    let clock: Double

    var body: some View {
        if engine.useLineMode {
            LineStyleView(engine: engine, t: t, palette: palette)
        } else {
            styled
        }
    }

    @ViewBuilder
    private var styled: some View {
        let style = engine.effectiveStyle
        switch style {
        case .poster:
            PosterStyleView(engine: engine, t: t, palette: palette)
        case .rise:
            RiseStyleView(engine: engine, t: t, palette: palette)
        case .electric:
            ElectricStyleView(engine: engine, t: t, palette: palette)
        case .stack, .stackVisual:
            StackStyleView(engine: engine, t: t, palette: palette, icons: style.usesIcons, variant: engine.stackVariant)
        case .classic, .karaoke, .bounce, .typewriter, .neon, .visual, .random:
            ClassicStyleView(engine: engine, t: t, palette: palette, icons: style.usesIcons, effect: style.effect)
        case .smooth:
            SmoothStyleView(engine: engine, t: t, palette: palette)
        case .spotlight:
            SpotlightStyleView(engine: engine, t: t, palette: palette)
        case .fisheye, .fisheyeVisual:
            FisheyeStyleView(engine: engine, t: t, palette: palette, icons: style.usesIcons)
        case .ship:
            ShipStyleView(engine: engine, t: t, palette: palette, icons: false, clock: clock)
        case .constellation:
            ConstellationStyleView(engine: engine, t: t, palette: palette, clock: clock)
        case .sway:
            SwayStyleView(engine: engine, t: t, palette: palette, clock: clock)
        }
    }
}

/// Everything behind the lyrics: dim, gradient, blurred cover, drifting color blobs, or cover + blobs.
struct BackdropView: View {
    let mode: BackdropMode
    let palette: Palette
    let image: NSImage?
    let clock: Double
    var sharp: NSImage? = nil          // full-size cover, faded in over the soft one
    var sharpness: Double = 0
    var zoom: Double = 1.0             // 1 = the cover just fills the screen
    var motion: Double = 0             // 0 = still; more = slow drift and breathing

    var body: some View {
        ZStack {
            switch mode {
            case .transparent:
                Color.clear
            case .dim:
                Color.black.opacity(0.45)
            case .gradient:
                if palette.isAuto {
                    gradient.opacity(0.92)
                } else {
                    Color.black.opacity(0.45)
                }
            case .cover:
                Color.black
                cover(moving: false)
                Color.black.opacity(0.3)
            case .fullArtwork:
                Color.black
            case .animated:
                Color.black
                blobs
                Color.black.opacity(0.25)
            case .coverAnimated:
                Color.black
                cover(moving: true)
                blobs.opacity(0.6).blendMode(.plusLighter)
                Color.black.opacity(0.3)
            }
        }
    }

    private var gradient: some View {
        LinearGradient(colors: [palette.backdropA, palette.backdropB], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder
    private func cover(moving: Bool) -> some View {
        if let image {
            GeometryReader { g in
                let m: Double = moving ? motion : 0.0
                let zoomD: Double = zoom + sin(clock * 0.15) * 0.04 * m
                let dx: CGFloat = CGFloat(sin(clock * 0.11) * 40.0 * m)
                let dy: CGFloat = CGFloat(cos(clock * 0.09) * 30.0 * m)
                ZStack {
                    // `image` is a tiny pre-shrunk copy: scaling it up is the soft look, nothing is blurred per frame.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                    if let sharp, sharpness > 0.02 {
                        Image(nsImage: sharp)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: g.size.width, height: g.size.height)
                            .opacity(sharpness)
                    }
                }
                .scaleEffect(CGFloat(zoomD))
                .offset(x: dx, y: dy)
                .clipped()
            }
        } else {
            gradient
        }
    }

    /// Soft color blobs drifting slowly, colors from the album (or your highlight color).
    private var blobs: some View {
        let colors: [Color] = palette.isAuto
            ? [palette.backdropA, palette.backdropB, palette.highlight, palette.lyric]
            : [palette.highlight, .purple, .blue, .pink]
        return GeometryReader { g in
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    BackdropBlob(color: colors[i % colors.count], index: i, clock: clock, area: g.size)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}


/// Lock-screen player bar: the same glass pill as the desktop player.
struct MusicWidgetView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        PlayerBar(engine: engine, lib: engine.library, showQueue: .constant(false), extras: false)
            .foregroundColor(.white)
            .environment(\.colorScheme, .dark)
            .frame(width: 720, height: 70)
    }
}

// MARK: - Artwork

/// Square artwork beside the lyrics. Animated: slow drift inside the frame, a gentle 3D sway and a pulsing glow.
struct ArtworkCard: View {
    let image: NSImage?
    let video: URL?
    let animated: Bool
    let glow: Color
    let clock: Double

    @State private var shown: NSImage? = nil
    @State private var flip: Double = -90

    private var key: ObjectIdentifier? { image.map { ObjectIdentifier($0) } }

    /// Turns the card over to show a new cover.
    private func turnOver() {
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.22)) { flip = 90 }
            try? await Task.sleep(nanoseconds: 230_000_000)
            shown = image
            flip = -90
            withAnimation(.spring(response: 0.75, dampingFraction: 0.7)) { flip = 0 }
        }
    }

    var body: some View {
        cardBody
            .onAppear {
                shown = image
                withAnimation(.spring(response: 0.9, dampingFraction: 0.68)) { flip = 0 }
            }
            .onChange(of: key) { _, _ in turnOver() }
    }

    private var cardBody: some View {
        GeometryReader { g in
            let side: CGFloat = min(g.size.width * 0.8, g.size.height * 0.5)
            let sway: Double = animated ? sin(clock * 0.6) * 14 : 0
            let nod: Double = animated ? cos(clock * 0.45) * 6 : 0
            let bob: CGFloat = animated ? CGFloat(sin(clock * 0.9)) * side * 0.012 : 0
            let sweepD: Double = (clock * 0.22).truncatingRemainder(dividingBy: 1.0)   // glint pass every ~4.5 s
            let sweep: CGFloat = CGFloat(sweepD * 2.6 - 0.8)
            let r: CGFloat = side * 0.07
            let shape = RoundedRectangle(cornerRadius: r, style: .continuous)

            ZStack {
                if animated {
                    // A slowly turning halo of the cover's color behind the card.
                    shape
                        .fill(AngularGradient(colors: [glow, glow.opacity(0.2), glow, glow.opacity(0.2), glow],
                                              center: .center, angle: .degrees(clock * 30.0)))
                        .frame(width: side * 1.04, height: side * 1.04)
                        .opacity(0.55)
                }
                face(side: side)
                    .frame(width: side, height: side)
                    .overlay {
                        if animated {
                            // Light glint sliding across the cover.
                            LinearGradient(colors: [.clear, Color.white.opacity(0.28), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: side * 0.45)
                                .rotationEffect(.degrees(20))
                                .offset(x: sweep * side)
                                .blendMode(.plusLighter)
                        }
                    }
                    .clipShape(shape)
                    .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
            .shadow(color: Color.black.opacity(0.45), radius: 22, y: 12)
            .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(sway), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(nod), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .offset(y: bob)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
    }

    @ViewBuilder
    private func face(side: CGFloat) -> some View {
        if animated, let video {
            VideoLoopView(url: video)
        } else if let image = shown ?? image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
        } else {
            ZStack {
                Color.white.opacity(0.12)
                Image(systemName: "music.note").font(.system(size: side * 0.3)).foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

/// Artwork filling the whole screen, moving slowly, dimmed so the lyrics stay readable.
struct ArtworkFill: View {
    let image: NSImage?
    let video: URL?
    let clock: Double
    var dim: Double = 0.5

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let video {
                    VideoLoopView(url: video)
                } else if let image {
                    // Whole cover, not a zoomed crop: a soft copy fills the screen, the sharp cover sits in front.
                    let zoomD: Double = 1.0 + 0.025 * sin(clock * 0.2)
                    let zoom = CGFloat(zoomD)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.low)
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .opacity(0.55)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(height: g.size.height * 0.9)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: Color.black.opacity(0.5), radius: 30)
                        .scaleEffect(zoom)
                }
                Color.black.opacity(dim)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
    }
}

/// A muted, endlessly looping video (your own file; Spotify Canvas / Apple motion artwork are not publicly available).
struct VideoLoopView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingPlayerView { LoopingPlayerView(url: url) }

    func updateNSView(_ view: LoopingPlayerView, context: Context) {
        if view.url != url { view.load(url) }
    }
}

final class LoopingPlayerView: NSView {
    private(set) var url: URL
    private var queue: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        load(url)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func load(_ newURL: URL) {
        url = newURL
        let q = AVQueuePlayer()
        q.isMuted = true
        looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: newURL))
        queue = q
        playerLayer.player = q
        q.play()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}


private struct BackdropBlob: View {
    let color: Color
    let index: Int
    let clock: Double
    let area: CGSize

    var body: some View {
        let f: Double = Double(index)
        let diameter: CGFloat = area.width * 0.55
        let ax: Double = sin(clock * (0.13 + f * 0.05) + f * 1.7)
        let ay: Double = cos(clock * (0.11 + f * 0.04) + f * 2.3)
        let dx: CGFloat = CGFloat(ax) * area.width * 0.3
        let dy: CGFloat = CGFloat(ay) * area.height * 0.3
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center,
                                 startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .offset(x: dx, y: dy)
            .opacity(0.85)
    }
}
