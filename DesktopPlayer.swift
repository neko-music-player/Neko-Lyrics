import AppKit
import SwiftUI

// MARK: - Where the player window sits

enum PlayerLevel: String, CaseIterable, Identifiable {
    case desktop, normal, top
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktop: return "On the desktop (behind apps)"
        case .normal: return "Like a normal window"
        case .top: return "Always on top"
        }
    }
}

// MARK: - Windows

/// Borderless window that can take typing (for the search box) but never becomes the main window.
final class GlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopController {
    private unowned let engine: Engine
    private var player: GlassWindow?
    private var wallpaper: NSWindow?
    private var wallpaperShown = false
    private var wallpaperHideTask: Task<Void, Never>?
    private var lockShown = false

    init(engine: Engine) { self.engine = engine }

    private static var desktopLevel: Int { Int(CGWindowLevelForKey(.desktopWindow)) }

    // MARK: Player

    private func ensurePlayer() {
        if player == nil {
            let size = Self.playerSize()
            let w = GlassWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isMovableByWindowBackground = engine.playerDraggable
            w.isReleasedWhenClosed = false
            let host = FirstMouseHostingView(rootView: DesktopPlayerView(engine: engine, lib: engine.library))
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            host.frame = NSRect(origin: .zero, size: size)
            w.contentView = host
            w.canBecomeVisibleWithoutLogin = true
            w.center()
            player = w
        }
    }

    /// Nearly full screen: the player is big enough that long lyrics never get squeezed.
    private static func playerSize() -> NSSize {
        let f: NSRect = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSSize(width: f.width * 0.9, height: f.height * 0.88)
    }

    private func fitPlayer() {
        guard let w = player else { return }
        let size: NSSize = Self.playerSize()
        let f: NSRect = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        w.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2 - f.height * 0.01,
                          width: size.width, height: size.height), display: true)
    }

    func applyDraggable() { player?.isMovableByWindowBackground = engine.playerDraggable }

    func showPlayer() {
        ensurePlayer()
        fitPlayer()
        updatePlayerLevel()
        player?.orderFrontRegardless()
        engine.library.refreshQueue()
        engine.library.refreshState()
    }

    func hidePlayer() {
        guard !lockShown else { return }       // keep it up while the lock screen is showing it
        player?.orderOut(nil)
    }

    // MARK: Lock screen: the same player, moved above the lock screen

    func syncLockPlayer(show: Bool) {
        guard show != lockShown else { return }
        lockShown = show
        if show {
            ensurePlayer()
            fitPlayer()
            guard let w = player else { return }
            w.level = NSWindow.Level(rawValue: Int(Int32.max - 1))
            w.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
            w.orderFrontRegardless()
            LockScreenLayer.shared.attach(w)
            LockScreenLayer.log("lock player shown, window \(w.windowNumber)")
            if let t = engine.track { engine.library.trackChanged(t) }
            engine.library.start()
        } else {
            updatePlayerLevel()
            if !engine.playerOpen {
                player?.orderOut(nil)
                engine.library.stop()
            }
        }
    }

    func updatePlayerLevel() {
        guard let w = player else { return }
        switch engine.playerLevel {
        case .desktop:
            w.level = NSWindow.Level(rawValue: Self.desktopLevel + 3)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .normal:
            w.level = .normal
            w.collectionBehavior = [.moveToActiveSpace]
        case .top:
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }

    // MARK: Live wallpaper (a window just above the real wallpaper, below desktop icons)

    /// The wallpaper stays up through the short gap between songs (playback briefly reads as "not playing"),
    /// and only fades away after a real pause. Before, a song change could start the fade-out, then the fade-in,
    /// and the fade-out's last step hid the window for good while the setting still said "on".
    func syncWallpaper(show: Bool) {
        if show {
            wallpaperHideTask?.cancel()
            wallpaperHideTask = nil
        } else {
            guard wallpaperShown, wallpaperHideTask == nil else { return }
            wallpaperHideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.wallpaperHideTask = nil
                self.wallpaperShown = false
                guard let w = self.wallpaper, w.isVisible else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.6
                    w.animator().alphaValue = 0
                }, completionHandler: {
                    Task { @MainActor [weak self] in
                        if self?.wallpaperShown == false { w.orderOut(nil) }
                    }
                })
            }
            return
        }
        guard !wallpaperShown else { return }
        wallpaperShown = true
        guard let screen = NSScreen.main else { return }
        if wallpaper == nil {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: Self.desktopLevel + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: WallpaperView(engine: engine))
            wallpaper = w
        }
        wallpaper?.setFrame(screen.frame, display: true)
        wallpaper?.alphaValue = 0
        wallpaper?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            wallpaper?.animator().alphaValue = 1
        }
    }
}

// MARK: - Glass look

struct GlassBackground: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(Color.black.opacity(0.25), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.6))
    }
}

extension View {
    func glass(_ radius: CGFloat = 18) -> some View { modifier(GlassBackground(radius: radius)) }
}

// MARK: - Wallpaper + big clock

struct WallpaperView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { tl in
            let clock: Double = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                if engine.videoURL != nil || engine.albumImage != nil {
                    ArtworkFill(image: engine.albumImage, video: engine.videoURL, clock: clock, dim: 0.35)
                } else {
                    BackdropView(mode: .animated, palette: engine.palette, image: nil, clock: clock)
                }
                if engine.showClock {
                    BigClock(color: engine.palette.highlight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 50)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Tall, thin, translucent clock with the date above it.
struct BigClock: View {
    let color: Color

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()
    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            VStack(spacing: -14) {
                Text(Self.date.string(from: tl.date))
                    .font(.system(size: 22, weight: .semibold))
                    .opacity(0.65)
                Text(Self.time.string(from: tl.date))
                    .font(.system(size: 250, weight: .thin))
                    .scaleEffect(x: 0.62, y: 1.0)
                    .frame(width: 400, height: 250)
            }
            .foregroundColor(color.opacity(0.6))
        }
    }
}

// MARK: - Dock icon: the album cover with a ring that beats

struct DockIconView: View {
    let image: NSImage?
    let kick: Double
    let color: Color

    var body: some View {
        let ringWidth: CGFloat = CGFloat(5.0 + 9.0 * kick)
        let ringAlpha: Double = 0.45 + 0.5 * kick
        let ringSize: CGFloat = CGFloat(224.0 + 18.0 * kick)
        ZStack {
            Circle()
                .stroke(color.opacity(ringAlpha), lineWidth: ringWidth)
                .frame(width: ringSize, height: ringSize)
                .blur(radius: 1.5)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(color.opacity(0.5))
                    .frame(width: 150, height: 150)
                    .overlay(Image(systemName: "music.note").font(.system(size: 60)).foregroundColor(.white))
            }
        }
        .frame(width: 256, height: 256)
    }
}

// MARK: - The desktop player

struct DesktopPlayerView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var lib: Library
    @State private var query = ""
    @State private var showQueue = true

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                if showQueue && engine.showControls {
                    QueuePanel(engine: engine, lib: lib)
                        .frame(width: 260)
                }
                centerArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .frame(maxHeight: .infinity)
            if engine.showControls {
                if !engine.isLocked { searchBar }       // the lock screen gives no keyboard to other apps
                PlayerBar(engine: engine, lib: lib, showQueue: $showQueue)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PlayerBackdrop(engine: engine) }
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.25)) { engine.showControls.toggle() } } label: {
                    Image(systemName: engine.showControls ? "slider.horizontal.below.rectangle" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .glass(14)
                }
                .buttonStyle(.plain)
                .help(engine.showControls ? "Hide the music controls" : "Show the music controls")
                Button {
                    if engine.isLocked { engine.lockAlbumBrowser.toggle() } else { engine.showAlbumBrowser.toggle() }
                } label: {
                    Image(systemName: browserAllowed ? "rectangle.stack.fill" : "rectangle.stack")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .glass(14)
                }
                .buttonStyle(.plain)
                .help(browserAllowed ? "Hide the album browser" : "Show the album browser")
                Button { engine.playerDraggable.toggle() } label: {
                    Image(systemName: engine.playerDraggable ? "hand.draw.fill" : "hand.draw")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .glass(14)
                }
                .buttonStyle(.plain)
                .help("Allow dragging the player")
                Button { engine.playerOpen = false } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .glass(14)
                }
                .buttonStyle(.plain)
                .help("Close the player")
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .glass(14)
                }
                .buttonStyle(.plain)
                .help("Quit Neko Lyrics")
            }
            .padding(12)
        }
    }

    private var searchLabel: String {
        engine.track?.source == .spotify ? "Search Spotify"
            : (lib.albumSource == .library ? "Search your music library" : "Search Apple Music")
    }

    private var hasLyricsHere: Bool {
        engine.lyricsEnabled && engine.playerShowsLyrics && engine.playerHostsLyrics && !engine.lines.isEmpty
    }

    /// The album browser can be switched off separately for the desktop and the lock screen.
    private var browserAllowed: Bool {
        engine.isLocked ? engine.lockAlbumBrowser : engine.showAlbumBrowser
    }

    @ViewBuilder
    private var centerArea: some View {
        if lib.searching || !lib.results.isEmpty || !lib.searchMessage.isEmpty {
            SearchResults(engine: engine, lib: lib)
        } else if hasLyricsHere || (!browserAllowed && engine.track != nil && lib.openedAlbum == nil) {
            PlayerStage(engine: engine, hasLyrics: hasLyricsHere, browserAllowed: browserAllowed)
        } else if let album = lib.openedAlbum {
            AlbumSongs(lib: lib, album: album)
        } else if engine.track == nil {
            Text("Play a song in Music or Spotify")
                .font(.callout)
                .opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lib.albums.isEmpty {
            Text(engine.track == nil ? "Play a song to see the artist's albums" : "Loading albums…")
                .font(.callout)
                .opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Picker("", selection: $lib.albumSource) {
                    ForEach(AlbumSource.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .overlay(alignment: .trailing) {
                    if lib.albumSource == .library {
                        Button { lib.reshuffle() } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 26, height: 26)
                                .glass(13)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 34)
                        .help("Show different albums")
                    }
                }
                if !lib.queueNotice.isEmpty { Text(lib.queueNotice).font(.caption).opacity(0.8) }
                CoverFlow(albums: lib.albums, center: $lib.center, art: lib.localArt,
                          need: { lib.ensureArt($0) },
                          open: { lib.showAlbum($0) },
                          play: { lib.playAlbum($0) },
                          reveal: { lib.openAlbum($0) },
                          queue: { lib.addAlbumToQueue($0, next: $1) })
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").opacity(0.6)
            TextField(searchLabel, text: $query)
                .textFieldStyle(.plain)
                .onSubmit { lib.search(query) }
            if !query.isEmpty {
                Button {
                    query = ""
                    lib.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill").opacity(0.6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glass(16)
        .frame(maxWidth: 620)
    }
}

// MARK: Queue

private struct QueuePanel: View {
    @ObservedObject var engine: Engine
    @ObservedObject var lib: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Playing").font(.headline)
            Text(engine.track?.source == .spotify ? "Spotify" : "Up next in Apple Music")
                .font(.caption)
                .opacity(0.6)
            if lib.queue.isEmpty {
                Text(lib.queueMessage).font(.caption).opacity(0.6)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lib.queue) { item in row(item) }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .glass(20)
    }

    private func row(_ item: QueueItem) -> some View {
        let current: Bool = item.title == engine.track?.title
        return Button { lib.play(item) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(item.artist).font(.system(size: 11)).opacity(0.6).lineLimit(1)
                }
                Spacer(minLength: 4)
                if current { Image(systemName: "waveform").font(.system(size: 11)) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Color.white.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Search results

private struct SearchResults: View {
    @ObservedObject var engine: Engine
    @ObservedObject var lib: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lib.albumSource == .library ? "Your library" : "Top Songs").font(.headline)
            if !lib.queueNotice.isEmpty { Text(lib.queueNotice).font(.caption).opacity(0.8) }
            else if lib.albumSource == .library { Text("Click plays next · right-click for more").font(.caption2).opacity(0.5) }
            if lib.searching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.caption).opacity(0.7)
                }
            } else if !lib.searchMessage.isEmpty {
                Text(lib.searchMessage).font(.caption).opacity(0.7)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(lib.results) { hit in row(hit) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(22)
    }

    private func row(_ hit: SongHit) -> some View {
        Button {
            if let pid = hit.persistentID { lib.addToQueue([pid]) } else {
                lib.open(link: hit.link, searchText: hit.title + " " + hit.artist)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Color.white.opacity(0.12)
                    if hit.persistentID != nil {
                        Image(systemName: "music.note").opacity(0.5)
                    } else {
                        AsyncImage(url: hit.art) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                        }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(hit.artist + " · " + hit.album).font(.system(size: 11)).opacity(0.6).lineLimit(1)
                }
                Spacer()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let pid = hit.persistentID {
                Button("Play next") { lib.addToQueue([pid]) }
                Button("Add to end of queue") { lib.addToQueue([pid], next: false) }
                Button("Play now (replaces queue)") { lib.playLocal(persistentID: pid) }
            }
        }
    }
}

/// One album as a list of songs. Tapping a song adds it to the queue instead of replacing the queue.
private struct AlbumSongs: View {
    @ObservedObject var lib: Library
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { lib.closeAlbum() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .glass(15)
                }
                .buttonStyle(.plain)
                if let img = lib.localArt[album.id] {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text(album.artist + (album.year.isEmpty ? "" : " · " + album.year))
                        .font(.system(size: 12)).opacity(0.65).lineLimit(1)
                }
                Spacer()
                Button { lib.addToQueue(lib.albumTracks.compactMap { $0.persistentID }) } label: {
                    Label("Play album next", systemImage: "text.insert")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glass(14)
                }
                .buttonStyle(.plain)
            }
            if !lib.queueNotice.isEmpty {
                Text(lib.queueNotice).font(.caption).opacity(0.8)
            }
            if lib.albumTracks.isEmpty {
                ProgressView().controlSize(.small)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(lib.albumTracks.enumerated()), id: \.element.id) { n, song in
                        Button {
                            if let pid = song.persistentID { lib.addToQueue([pid]) }
                        } label: {
                            HStack(spacing: 10) {
                                Text(String(n + 1)).font(.system(size: 12)).opacity(0.5).frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(song.artist).font(.system(size: 11)).opacity(0.6).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").opacity(0.7)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let pid = song.persistentID {
                                Button("Play next") { lib.addToQueue([pid]) }
                                Button("Add to end of queue") { lib.addToQueue([pid], next: false) }
                                Button("Play now (replaces queue)") { lib.playLocal(persistentID: pid) }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(22)
    }
}

// MARK: Cover flow

struct CoverFlow: View {
    let albums: [Album]
    @Binding var center: Int
    let art: [String: NSImage]
    let need: (Album) -> Void
    let open: (Album) -> Void
    var play: (Album) -> Void = { _ in }
    var reveal: (Album) -> Void = { _ in }
    var queue: (Album, Bool) -> Void = { _, _ in }

    /// While you scroll or drag the position is fractional, so the covers glide; it settles on a whole cover after.
    @State private var live: Double? = nil
    @State private var settle: Task<Void, Never>? = nil
    @State private var dragStart: Double? = nil

    private func position() -> Double { live ?? Double(center) }

    var body: some View {
        GeometryReader { g in
            let card: CGFloat = min(g.size.height * 0.62, 260)
            let pos: Double = position()
            let spacing: Double = Double(g.size.width) * 0.12
            let mid: Int = Int(pos.rounded())
            let lo: Int = max(0, mid - 3)
            let hi: Int = min(albums.count - 1, mid + 3)
            ZStack {
                if lo <= hi {
                    ForEach(lo...hi, id: \.self) { i in
                        let d: Double = Double(i) - pos
                        FlowCard(album: albums[i], image: art[albums[i].id], d: d, card: card,
                                 width: g.size.width, current: abs(d) < 0.5)
                            .onTapGesture { tap(i) }
                            .contextMenu {
                                Button("Play album next") { queue(albums[i], true) }
                                Button("Add album to end of queue") { queue(albums[i], false) }
                                Button("Show songs") { open(albums[i]) }
                                Button("Show in Music (keeps your queue)") { reveal(albums[i]) }
                                Button("Play album now (replaces queue)") { play(albums[i]) }
                            }
                            .onAppear { need(albums[i]) }
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        if dragStart == nil { dragStart = position() }
                        let moved: Double = Double(-v.translation.width) / max(spacing, 1)
                        live = clamp((dragStart ?? 0) + moved)
                    }
                    .onEnded { v in
                        let predicted: Double = Double(-v.predictedEndTranslation.width) / max(spacing, 1)
                        let target: Double = clamp(((dragStart ?? position()) + predicted * 0.6).rounded())
                        dragStart = nil
                        land(on: Int(target))
                    }
            )
            .background(
                ScrollCatcher { dx, dy in
                    // Two-finger trackpad swipe (or a mouse wheel): glide with the fingers.
                    let delta: Double = abs(dx) >= abs(dy) ? dx : -dy
                    live = clamp(position() - delta / max(spacing * 1.6, 1))
                    settle?.cancel()
                    settle = Task {
                        try? await Task.sleep(nanoseconds: 140_000_000)
                        guard !Task.isCancelled else { return }
                        land(on: Int(position().rounded()))
                    }
                }
            )
            .overlay(alignment: .leading) { arrow("chevron.left") { step(-1) } }
            .overlay(alignment: .trailing) { arrow("chevron.right") { step(1) } }
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), Double(max(albums.count - 1, 0))) }

    private func land(on index: Int) {
        let target: Int = min(max(index, 0), max(albums.count - 1, 0))
        withAnimation(.interpolatingSpring(stiffness: 170, damping: 22)) {
            center = target
            live = nil
        }
    }

    private func arrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .glass(15)
        }
        .buttonStyle(.plain)
    }

    private func step(_ s: Int) { land(on: Int(position().rounded()) + s) }

    private func tap(_ i: Int) {
        if i == Int(position().rounded()) {
            open(albums[i])
        } else {
            land(on: i)
        }
    }
}

/// Reports trackpad / wheel scrolling over a region without blocking clicks.
struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (Double, Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((Double, Double) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks pass through

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p: NSPoint = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                self.onScroll?(Double(e.scrollingDeltaX), Double(e.scrollingDeltaY))
                return nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

private struct FlowCard: View, Animatable {
    let album: Album
    let image: NSImage?
    var d: Double
    let card: CGFloat
    let width: CGFloat
    let current: Bool

    var animatableData: Double {
        get { d }
        set { d = newValue }
    }

    @ViewBuilder
    private var cover: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.medium).scaledToFill()
        } else if album.local {
            placeholder
        } else {
            AsyncImage(url: album.art) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.12)
            Image(systemName: "music.note").font(.system(size: 40)).opacity(0.5)
        }
    }

    var body: some View {
        let dd: Double = d
        let ad: Double = abs(dd)
        let scale: CGFloat = CGFloat(1.0 - ad * 0.13)
        let gap: CGFloat = CGFloat(max(-1.0, min(1.0, dd * 2.0)) * 46.0)
        let spread: CGFloat = CGFloat(dd) * width * 0.12 + gap
        let angle: Double = max(-55.0, min(55.0, -dd * 38.0))
        let alpha: Double = 1.0 - ad * 0.18

        cover
        .frame(width: card, height: card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 0.8))
        .shadow(color: Color.black.opacity(current ? 0.4 : 0), radius: 12, y: 8)
        .overlay(alignment: .bottom) {
            if current {
                VStack(spacing: 1) {
                    Text(album.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(album.year.isEmpty ? "Album" : album.year + " · Album").font(.system(size: 11)).opacity(0.7)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glass(12)
                .offset(y: 52)
            }
        }
        .scaleEffect(scale)
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .offset(x: spread)
        .opacity(alpha)
        .zIndex(-ad)
    }
}

// MARK: Player bar

struct PlayerBar: View {
    @ObservedObject var engine: Engine
    @ObservedObject var lib: Library
    @Binding var showQueue: Bool
    var extras: Bool = true     // lyrics / queue buttons (off on the lock screen)
    @State private var scrub: Double? = nil

    var body: some View {
        HStack(spacing: 14) {
            icon("shuffle", 13, on: lib.shuffle) { lib.toggleShuffle() }
            icon("backward.fill", 16) { engine.previousTrack() }
            icon(engine.isPlaying ? "pause.fill" : "play.fill", 20) { engine.playPause() }
            icon("forward.fill", 16) { engine.nextTrack() }
            icon("repeat", 13, on: lib.repeating) { lib.toggleRepeat() }

            nowPlaying
                .frame(maxWidth: .infinity)

            if extras {
                icon("text.bubble", 15, on: engine.playerShowsLyrics) { engine.playerShowsLyrics.toggle() }
                icon("list.bullet", 15, on: showQueue) { showQueue.toggle() }
            }
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 13)).opacity(0.8)
            Slider(value: Binding(get: { lib.volume }, set: { lib.setVolume($0) }), in: 0...1)
                .frame(width: 70)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glass(26)
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.track?.title ?? "Nothing playing")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(engine.track?.artist ?? "")
                    .font(.system(size: 11))
                    .opacity(0.6)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    progress
                }
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let img = engine.albumImage {
            Image(nsImage: img).resizable().scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.14))
                .frame(width: 38, height: 38)
        }
    }

    private var progress: some View {
        let total: Double = max(engine.track?.duration ?? 0, 1)
        let now: Double = min(max(engine.currentTime - Engine.latencyLead - engine.offset, 0), total)
        let shown: Double = scrub ?? (now / total)
        let frac: CGFloat = CGFloat(shown)
        return GeometryReader { g in
            let w: CGFloat = max(g.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: 5)
                Capsule().fill(Color.white.opacity(0.92)).frame(width: w * frac, height: 5)
                Circle().fill(Color.white)
                    .frame(width: scrub == nil ? 0 : 11, height: scrub == nil ? 0 : 11)
                    .offset(x: w * frac - 5.5)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(max(Double(v.location.x / w), 0), 1) }
                    .onEnded { v in
                        let f: Double = min(max(Double(v.location.x / w), 0), 1)
                        engine.seek(fraction: f)
                        scrub = nil
                    }
            )
        }
        .frame(height: 14)
    }

    private func icon(_ name: String, _ size: CGFloat, on: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .bold))
                .opacity(on ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
    }
}


/// The middle of the player: the cover and, once there are lyrics, the lyrics beside it. The cover glides from the
/// centre to the left (and flips when the album changes) instead of jumping.
private struct PlayerStage: View {
    @ObservedObject var engine: Engine
    let hasLyrics: Bool
    let browserAllowed: Bool

    private var showCard: Bool { hasLyrics ? engine.artwork.isCard : true }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let clock: Double = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                if showCard {
                    VStack(spacing: 14) {
                        ArtworkCard(image: engine.albumImage, video: engine.videoURL,
                                    animated: engine.artwork == .animated, glow: engine.palette.highlight, clock: clock)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !hasLyrics, let track = engine.track {
                            VStack(spacing: 3) {
                                Text(track.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                                Text(track.artist).font(.system(size: 14)).opacity(0.65).lineLimit(1)
                                if engine.lyricsEnabled && engine.lines.isEmpty {
                                    Text(engine.status).font(.caption).opacity(0.5)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .frame(width: hasLyrics ? 300 : nil)
                    .frame(maxWidth: hasLyrics ? 300 : .infinity)
                }
                if hasLyrics {
                    LyricsStyleHost(engine: engine, t: engine.currentTime, palette: engine.palette, clock: clock)
                        .shadow(color: Color.black.opacity(0.6), radius: 8)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(.spring(response: 0.75, dampingFraction: 0.82), value: hasLyrics)
        }
    }
}

/// A hosting view that reacts to the very first click, even when its window is not the active one
/// (on the lock screen the player never becomes active, so sliders and buttons need this).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}


/// The player's own background: whichever Background you chose in Look (the desktop lyrics window is not
/// drawn while the player is open, so the choice used to have no effect there).
private struct PlayerBackdrop: View {
    @ObservedObject var engine: Engine

    private var moves: Bool {
        engine.background == .animated || engine.background == .coverAnimated || engine.background == .fullArtwork
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        Group {
            if moves {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { tl in
                    layers(clock: tl.date.timeIntervalSinceReferenceDate)
                }
            } else {
                layers(clock: 0)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.8))
    }

    @ViewBuilder
    private func layers(clock: Double) -> some View {
        ZStack {
            if engine.background == .transparent {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.25)
            } else {
                BackdropView(mode: engine.background, palette: engine.palette,
                             image: engine.albumSmall ?? engine.albumImage, clock: clock,
                             sharp: engine.albumImage, sharpness: engine.coverSharpness,
                             zoom: engine.coverZoom, motion: engine.coverMotion)
                if engine.background == .fullArtwork {
                    ArtworkFill(image: engine.albumImage, video: engine.videoURL, clock: clock)
                }
                Color.black.opacity(0.18)       // keeps the white controls readable on bright covers
            }
        }
    }
}
