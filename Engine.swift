import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Engine: ObservableObject {
    static let noneID = "none"

    @Published var track: Track?
    @Published var lines: [Line] = []
    @Published var isPlaying = false
    @Published var status = "Waiting for music…"
    @Published var isLocked = false {
        didSet {
            LockScreenLayer.log("isLocked = \(isLocked)")
            refresh()
        }
    }
    @Published var lyricColor = Color.white
    @Published var highlightColor = Color.yellow
    @Published var previewing = false { didSet { refresh() } }

    @Published var lockedOnly: Bool = UserDefaults.standard.object(forKey: "lockedOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lockedOnly, forKey: "lockedOnly"); refresh() }
    }
    /// Seconds added to the playback clock. Positive = lyrics appear earlier.
    /// Per-song: starts at 0 for every song, and is saved with the lyrics when you tick "Correct".
    @Published var offset: Double = 0 {
        didSet { if !suppressOffsetSave { scheduleOffsetSave() } }
    }
    private var suppressOffsetSave = false
    private var offsetTask: Task<Void, Never>?

    private func setOffsetQuietly(_ value: Double) {
        suppressOffsetSave = true
        offset = value
        suppressOffsetSave = false
    }

    /// Once the lyrics are confirmed, offset changes are saved by themselves (after you stop moving the slider).
    private func scheduleOffsetSave() {
        guard confirmed, !currentKey.isEmpty else { return }
        offsetTask?.cancel()
        let key = currentKey
        offsetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, self.currentKey == key, var entry = self.cache.entry(for: key) else { return }
            entry.songOffset = abs(self.offset) < 0.001 ? nil : self.offset
            self.cache.set(entry, for: key)
        }
    }
    @Published var style: LyricStyle = LyricStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .classic {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "style") }
    }
    @Published var autoSync: Bool = UserDefaults.standard.bool(forKey: "autoSync") {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: "autoSync")
            if needsArtwork, albumPalette == nil, let t = track { loadArtwork(for: t) }
        }
    }
    @Published var albumPalette: Palette?
    @Published var albumImage: NSImage?
    @Published var albumSmall: NSImage?          // 48 px copy, used as the blurred backdrop
    @Published var background: BackdropMode = BackdropMode(rawValue: UserDefaults.standard.string(forKey: "background") ?? "") ?? .gradient {
        didSet {
            UserDefaults.standard.set(background.rawValue, forKey: "background")
            if needsArtwork, albumImage == nil, let t = track { loadArtwork(for: t) }
        }
    }

    @Published var showWidget: Bool = UserDefaults.standard.object(forKey: "showWidget") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showWidget, forKey: "showWidget")
            if needsArtwork, albumImage == nil, let t = track { loadArtwork(for: t) }
            refresh()
        }
    }

    @Published var artwork: ArtworkMode = ArtworkMode(rawValue: UserDefaults.standard.string(forKey: "artwork") ?? "") ?? .none {
        didSet {
            UserDefaults.standard.set(artwork.rawValue, forKey: "artwork")
            if needsArtwork, albumImage == nil, let t = track { loadArtwork(for: t) }
        }
    }
    /// Your own looping video per song (track key -> file path). Used by the animated artwork modes.
    @Published var videoPaths: [String: String] = UserDefaults.standard.dictionary(forKey: "videoPaths") as? [String: String] ?? [:]

    var videoURL: URL? {
        guard let key = track?.key, let p = videoPaths[key], FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    func chooseVideo() {
        guard let key = track?.key else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a short looping video for this song"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        videoPaths[key] = url.path
        UserDefaults.standard.set(videoPaths, forKey: "videoPaths")
    }

    func removeVideo() {
        guard let key = track?.key else { return }
        videoPaths[key] = nil
        UserDefaults.standard.set(videoPaths, forKey: "videoPaths")
    }

    @Published var stackMotion: StackMotion = StackMotion(rawValue: UserDefaults.standard.string(forKey: "stackMotion") ?? "") ?? .random {
        didSet { UserDefaults.standard.set(stackMotion.rawValue, forKey: "stackMotion") }
    }
    /// Ambient light around the screen edges, colored by the album art and kicked by each sung word.
    @Published var edgeLight: Bool = UserDefaults.standard.bool(forKey: "edgeLight") {
        didSet { UserDefaults.standard.set(edgeLight, forKey: "edgeLight"); refresh() }
    }
    @Published var edgeThickness: Double = UserDefaults.standard.object(forKey: "edgeThickness") as? Double ?? 14 {
        didSet { UserDefaults.standard.set(edgeThickness, forKey: "edgeThickness") }
    }
    @Published var edgeRadius: Double = UserDefaults.standard.object(forKey: "edgeRadius") as? Double ?? 14 {
        didSet { UserDefaults.standard.set(edgeRadius, forKey: "edgeRadius") }
    }
    /// Music controls (search + player bar + queue) can be tucked away, on the desktop and the lock screen alike.
    @Published var showControls: Bool = UserDefaults.standard.object(forKey: "showControls") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showControls, forKey: "showControls") }
    }
    @Published var edgeGlow: Double = UserDefaults.standard.object(forKey: "edgeGlow") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(edgeGlow, forKey: "edgeGlow") }
    }

    /// 1 right when a word starts, fading to 0 over about a second. Used to pulse the edge light.
    func kick(at t: TimeInterval) -> Double {
        guard let li = lineIndex(at: t) else { return 0 }
        let line = lines[li]
        guard let wi = line.words.lastIndex(where: { $0.start <= t }) else { return 0 }
        let age: Double = max(0, t - line.words[wi].start)
        let strength: Double = wi == 0 ? 1.0 : 0.7
        return strength * exp(-age * 4.5)
    }

    // MARK: Desktop features (player window, live wallpaper, clock, dock icon)

    let library = Library()

    @Published var playerOpen: Bool = UserDefaults.standard.bool(forKey: "playerOpen") {
        didSet { UserDefaults.standard.set(playerOpen, forKey: "playerOpen"); applyDesktop() }
    }
    @Published var playerLevel: PlayerLevel = PlayerLevel(rawValue: UserDefaults.standard.string(forKey: "playerLevel") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(playerLevel.rawValue, forKey: "playerLevel"); desktop.updatePlayerLevel() }
    }
    @Published var liveWallpaper: Bool = UserDefaults.standard.bool(forKey: "liveWallpaper") {
        didSet {
            UserDefaults.standard.set(liveWallpaper, forKey: "liveWallpaper")
            if needsArtwork, albumImage == nil, let t = track { loadArtwork(for: t) }
            refresh()
        }
    }
    @Published var showClock: Bool = UserDefaults.standard.object(forKey: "showClock") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showClock, forKey: "showClock") }
    }
    @Published var dockIcon: Bool = UserDefaults.standard.bool(forKey: "dockIcon") {
        didSet { UserDefaults.standard.set(dockIcon, forKey: "dockIcon"); applyDock() }
    }
    /// The lyrics button in the player: turns the lyrics overlay on or off.
    @Published var lyricsEnabled: Bool = UserDefaults.standard.object(forKey: "lyricsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lyricsEnabled, forKey: "lyricsEnabled"); refresh() }
    }

    /// Draw the lyrics above all your apps (not just on the desktop and lock screen).
    @Published var lyricsAboveApps: Bool = UserDefaults.standard.bool(forKey: "lyricsAboveApps") {
        didSet { UserDefaults.standard.set(lyricsAboveApps, forKey: "lyricsAboveApps"); refresh() }
    }
    /// While the desktop player is open: lyrics in its middle (true) or the album cover flow (false).
    @Published var playerShowsLyrics: Bool = UserDefaults.standard.object(forKey: "playerShowsLyrics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(playerShowsLyrics, forKey: "playerShowsLyrics") }
    }

    /// Show the full desktop player (cover flow, queue, controls) on the lock screen too.
    @Published var showLockPlayer: Bool = UserDefaults.standard.object(forKey: "showLockPlayer") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLockPlayer, forKey: "showLockPlayer"); refresh() }
    }

    private var dockTimer: Timer?
    private var dockWasOn = false

    func applyDesktop() {
        if playerOpen {
            library.start()
            if let t = track { library.trackChanged(t) }
            if needsArtwork, albumImage == nil, let t = track { loadArtwork(for: t) }
            desktop.showPlayer()
        } else {
            desktop.hidePlayer()
            library.stop()
        }
        refresh()
    }

    func applyDock() {
        dockTimer?.invalidate()
        dockTimer = nil
        if !dockIcon && !dockWasOn { return }       // nothing to undo: leave the menu bar app alone at launch
        let app = NSApplication.shared
        dockWasOn = dockIcon
        if dockIcon {
            app.setActivationPolicy(.regular)
            if needsArtwork, albumImage == nil, let t = track { loadArtwork(for: t) }
            updateDockIcon()
            dockTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDockIcon() }
            }
        } else {
            app.applicationIconImage = nil
            app.setActivationPolicy(.accessory)
        }
    }

    private func updateDockIcon() {
        let k: Double = isPlaying ? kick(at: currentTime) : 0
        let view = DockIconView(image: albumImage, kick: k, color: palette.highlight.vivid)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let img = renderer.nsImage { NSApplication.shared.applicationIconImage = img }
    }

    /// Jump to a point in the song (0...1), from the player's progress bar.
    func seek(fraction: Double) {
        guard let tr = track, tr.duration > 0 else { return }
        let secs: Double = min(max(fraction, 0), 1) * tr.duration
        NowPlayingMonitor.seek(to: secs, source: tr.source)
        anchorPos = secs
        anchorDate = Date()
        refresh()
    }

    /// Vertical position of the music widget, as a fraction of the screen height measured from the bottom.
    @Published var widgetFraction: Double = UserDefaults.standard.object(forKey: "widgetFraction") as? Double ?? 0.14 {
        didSet {
            UserDefaults.standard.set(widgetFraction, forKey: "widgetFraction")
            refresh()
        }
    }

    /// Cover background: how far it is zoomed (1 = exactly fills the screen) and how much it drifts.
    @Published var coverZoom: Double = UserDefaults.standard.object(forKey: "coverZoom") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(coverZoom, forKey: "coverZoom") }
    }
    @Published var coverMotion: Double = UserDefaults.standard.object(forKey: "coverMotion") as? Double ?? 0.35 {
        didSet { UserDefaults.standard.set(coverMotion, forKey: "coverMotion") }
    }

    /// The album browser (cover flow) can be hidden on the desktop and on the lock screen separately.
    @Published var showAlbumBrowser: Bool = UserDefaults.standard.object(forKey: "showAlbumBrowser") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAlbumBrowser, forKey: "showAlbumBrowser") }
    }
    @Published var lockAlbumBrowser: Bool = UserDefaults.standard.object(forKey: "lockAlbumBrowser") as? Bool ?? false {
        didSet { UserDefaults.standard.set(lockAlbumBrowser, forKey: "lockAlbumBrowser") }
    }

    /// Show lyrics in Latin letters (Japanese, Korean, Hindi/Nepali, Arabic, Russian ...).
    @Published var romanize: Bool = UserDefaults.standard.bool(forKey: "romanize") {
        didSet {
            UserDefaults.standard.set(romanize, forKey: "romanize")
            if let c = candidate { lines = LRC.parse(romanize ? Romanizer.convertLRC(c.lrc) : c.lrc, trackEnd: track?.duration ?? 0) }
        }
    }

    /// 0 = soft blurred cover background, 1 = the sharp cover.
    @Published var coverSharpness: Double = UserDefaults.standard.object(forKey: "coverSharpness") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(coverSharpness, forKey: "coverSharpness") }
    }

    /// True when the lyrics only have line timestamps (word times would be guesses).
    @Published var lineTimedOnly = false

    /// Line-timed songs get a whole-line effect instead of word effects built on guessed timing.
    @Published var lineModeAuto: Bool = UserDefaults.standard.object(forKey: "lineModeAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lineModeAuto, forKey: "lineModeAuto") }
    }
    var useLineMode: Bool { lineModeAuto && lineTimedOnly }

    /// The style actually drawn: "Random per song" picks one by the song, the same one every time for that song.
    var effectiveStyle: LyricStyle {
        guard style == .random, let key = track?.key else { return style == .random ? .stack : style }
        let pool = LyricStyle.randomPool
        return pool[Int(StableHash.value(key, salt: 1) % UInt64(pool.count))]
    }

    /// How Poster moves: the Stack motion setting (topple / turn), or one picked per song.
    var posterMotion: PosterMotion {
        switch stackMotion {
        case .topple: return .topple
        case .turn: return .turn
        case .random:
            let pool: [PosterMotion] = [.topple, .flat, .turn, .topple]
            return pool[Int(StableHash.value(track?.key ?? "", salt: 3) % UInt64(pool.count))]
        default: return .flat
        }
    }

    var stackVariant: StackVariant {
        if let v = stackMotion.variant { return v }
        let all = StackVariant.allCases
        let key = track?.key ?? ""
        return all[Int(StableHash.value(key, salt: 2) % UInt64(all.count))]
    }

    /// Rough brightness of what is drawn behind the lyrics, used to keep the text readable.
    var backdropLuminance: Double {
        switch background {
        case .transparent: return 0.15
        case .dim: return 0.05
        case .gradient:
            if autoSync, let p = albumPalette { return (p.backdropA.luminance + p.backdropB.luminance) / 2 * 0.92 }
            return 0.05
        case .cover, .animated, .coverAnimated, .fullArtwork: return 0.18
        }
    }

    /// Cover art is fetched when colors, the backdrop, the artwork or the music widget want it.
    var needsArtwork: Bool { autoSync || edgeLight || background.usesCover || showWidget || artwork != .none || liveWallpaper || playerOpen || dockIcon || showLockPlayer }

    /// True while the glass player is on screen and carries the lyrics itself (desktop or lock screen).
    var playerHostsLyrics: Bool {
        (playerOpen && !lyricsAboveApps && !isLocked) || (isLocked && showLockPlayer)
    }

    /// Lets the player window be dragged by its background. Off by default so sliders and buttons always work.
    @Published var playerDraggable: Bool = UserDefaults.standard.bool(forKey: "playerDraggable") {
        didSet {
            UserDefaults.standard.set(playerDraggable, forKey: "playerDraggable")
            desktop.applyDraggable()
        }
    }

    /// Kill switch: turns every Neko Lyrics feature off and hides all its windows (the app stays in the menu bar).
    func stopEverything() {
        previewing = false
        playerOpen = false
        liveWallpaper = false
        showClock = false
        edgeLight = false
        lyricsEnabled = false
        showLockPlayer = false
        showWidget = false
        dockIcon = false
        overlay.hide()
        desktop.syncLockPlayer(show: false)
        desktop.hidePlayer()
    }

    private var hotKeyMonitors: [Any] = []

    /// Control + Option + Command + Q quits the app from anywhere (global monitor needs the Input Monitoring permission).
    func installKillHotkey() {
        guard hotKeyMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { e in
            let want: NSEvent.ModifierFlags = [.control, .option, .command]
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: want),
               e.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApplication.shared.terminate(nil)
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { hotKeyMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in handler(e); return e }) { hotKeyMonitors.append(l) }
    }

    func playPause() { if let s = track?.source { NowPlayingMonitor.transport("playpause", source: s) } }
    func nextTrack() { if let s = track?.source { NowPlayingMonitor.transport("next track", source: s) } }
    func previousTrack() { if let s = track?.source { NowPlayingMonitor.transport("previous track", source: s) } }

    @Published var fontFamily: String = UserDefaults.standard.string(forKey: "fontFamily") ?? LyricFont.roundedID {
        didSet { UserDefaults.standard.set(fontFamily, forKey: "fontFamily") }
    }
    @Published var fontWeight: Int = UserDefaults.standard.object(forKey: "fontWeight") as? Int ?? LyricFont.defaultWeightIndex {
        didSet { UserDefaults.standard.set(fontWeight, forKey: "fontWeight") }
    }
    @Published var fontScale: Double = UserDefaults.standard.object(forKey: "fontScale") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(fontScale, forKey: "fontScale") }
    }
    @Published var searchSummary = ""

    // Lyrics selection state (drives the tick / cross UI)
    @Published var candidate: LyricsCandidate?
    @Published var confirmed = false
    @Published var hidden = false
    @Published var showPicker = false
    @Published var alternatives: [LyricsCandidate] = []
    @Published var searching = false
    @Published var pickerMessage = ""
    @Published var fileMessage = ""

    /// Seconds the lyrics run ahead of the player clock: reading the position (AppleScript) and drawing a frame
    /// both take time, and lyrics that appear a hair early feel in sync. Fine-tune with the Sync offset slider.
    static let latencyLead: TimeInterval = 0.25

    private var anchorPos: TimeInterval = 0
    private var anchorDate = Date()

    private let monitor = NowPlayingMonitor()
    private let provider: LyricsProvider = WordFirstProvider()
    private let cache = LyricsCache()
    private let awake = AwakeAssertion()
    private let phone = PhoneSync()
    private var fetchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var artTask: Task<Void, Never>?
    private var currentKey = ""
    private var localPath: String?
    private lazy var overlay = OverlayController(engine: self)
    private lazy var desktop = DesktopController(engine: self)

    init() {
        installKillHotkey()
        monitor.onChange = { [weak self] snap in self?.apply(snap) }
        monitor.start()

        phone.onPeerConnected = { [weak self] in
            MainActor.assumeIsolated { self?.pushToPhone(full: true) }
        }
        phone.start()

        // Undocumented but long-stable lock/unlock notifications.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLocked = true }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLocked = false }
        }

        library.currentSource = { [weak self] in self?.track?.source }
        // Windows are created a moment after launch, once the app is fully running.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.applyDesktop()
            self?.applyDock()
        }
    }

    /// Playback time, interpolated between AppleScript position readings.
    var currentTime: TimeInterval {
        (isPlaying ? anchorPos + Date().timeIntervalSince(anchorDate) : anchorPos) + offset + Engine.latencyLead
    }

    func lineIndex(at t: TimeInterval) -> Int? {
        lines.lastIndex { $0.start <= t }
    }

    /// Fractional line index, easing from one line to the next. Drives the scrolling styles.
    func scrollPosition(at t: TimeInterval) -> Double {
        guard let idx = lineIndex(at: t) else { return -1 }
        let p = min(max((t - lines[idx].start) / 0.45, 0), 1)
        return Double(idx - 1) + p * p * (3 - 2 * p)
    }

    /// Colors in use: the album palette when Auto Sync is on and art was found, else your three picks.
    /// "Random font": each song gets a font and weight of its own, the same one every time.
    private static let fontPool: [String] = [
        LyricFont.roundedID, LyricFont.serifID, LyricFont.systemID,
        "Cooper Black", "Futura", "Avenir Next", "Georgia", "Didot", "Baskerville", "Marker Felt",
        "Chalkboard SE", "Optima", "Gill Sans", "Rockwell", "Trebuchet MS", "Hoefler Text", "Palatino", "Copperplate",
    ]

    private var chosenFont: LyricFont {
        guard fontRandom, !currentKey.isEmpty else {
            return LyricFont(family: fontFamily, weightIndex: fontWeight, scale: fontScale)
        }
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let pool: [String] = Self.fontPool.filter { $0.hasPrefix("system") || installed.contains($0) }
        let h: UInt64 = StableHash.value(currentKey, salt: 91)
        let family: String = pool.isEmpty ? LyricFont.roundedID : pool[Int(h % UInt64(pool.count))]
        let weights: [Int] = [3, 4, 5, 6]
        let weight: Int = weights[Int((h / 97) % UInt64(weights.count))]
        return LyricFont(family: family, weightIndex: weight, scale: fontScale)
    }

    @Published var fontRandom: Bool = UserDefaults.standard.bool(forKey: "fontRandom") {
        didSet { UserDefaults.standard.set(fontRandom, forKey: "fontRandom") }
    }

    var palette: Palette {
        let font = chosenFont
        if autoSync, var p = albumPalette {
            p.font = font
            return p.fixed(backdrop: backdropLuminance)
        }
        let manual = Palette(lyric: lyricColor, highlight: highlightColor, secondary: lyricColor.opacity(0.4),
                             backdropA: .black, backdropB: .black, isAuto: false, font: font)
        return manual.fixed(backdrop: backdropLuminance)
    }

    var sourceFileName: String? { localPath.map { URL(fileURLWithPath: $0).lastPathComponent } }
    var canWriteToFile: Bool { localPath != nil && candidate != nil }

    // MARK: - Track changes

    private func apply(_ snap: NowPlayingMonitor.Snapshot) {
        let trackChanged = snap.track != track
        if let p = snap.position {
            anchorPos = p
            anchorDate = Date()
        } else if trackChanged {
            anchorPos = 0
            anchorDate = Date()
        }   // else: the player couldn't be asked this time; keep the running clock instead of jumping to 0
        isPlaying = snap.isPlaying

        if trackChanged {
            track = snap.track
            resetLyrics()
            if let t = snap.track {
                loadLyrics(for: t)
                albumImage = nil
                albumSmall = nil
                if needsArtwork { loadArtwork(for: t) }
                if playerOpen { library.trackChanged(t) }
            } else {
                status = "Waiting for music…"
                albumPalette = nil
                albumImage = nil
                albumSmall = nil
            }
        }
        pushToPhone(full: false)
        refresh()
    }

    private func resetLyrics() {
        fetchTask?.cancel()
        searchTask?.cancel()
        lines = []
        candidate = nil
        confirmed = false
        hidden = false
        showPicker = false
        alternatives = []
        searching = false
        pickerMessage = ""
        fileMessage = ""
        localPath = nil
        currentKey = ""
        setOffsetQuietly(0)
        pushToPhone(full: true)
    }

    private func loadArtwork(for t: Track) {
        artTask?.cancel()
        let key = t.key
        artTask = Task { [weak self] in
            guard let self else { return }
            let image = await AlbumArt.image(for: t)
            guard !Task.isCancelled, self.currentKey == key else { return }
            self.albumImage = image
            self.albumSmall = image.map { AlbumArt.small($0) }
            self.albumPalette = image.flatMap { AlbumArt.palette(from: $0) }
        }
    }

    /// Order of preference:
    ///   1. lyrics you confirmed (cache)           - no file access, no network
    ///   2. lyrics embedded in the file / .lrc     - local
    ///   3. lyrics picked automatically before     - cache
    ///   4. LRCLIB                                 - network
    private func loadLyrics(for t: Track) {
        let key = t.key
        currentKey = key
        localPath = NowPlayingMonitor.filePath(for: t.source)

        let saved = cache.entry(for: key)
        setOffsetQuietly(saved?.confirmed == true ? (saved?.songOffset ?? 0) : 0)
        let savedChoice = saved.flatMap { e in e.candidates.first { $0.id == e.chosenID } }

        if let e = saved, e.chosenID == Self.noneID {
            hidden = true
            confirmed = true
            status = "Lyrics hidden for this song"
            return
        }
        if let c = savedChoice, saved?.confirmed == true {
            use(c, confirmed: true)
            return
        }

        let embedded = localPath.map { EmbeddedLyrics.read(path: $0) }
        if let first = embedded?.candidates.first {
            use(first, confirmed: false)
            persist(first, confirmed: false, extras: embedded?.candidates ?? [])
            return
        }
        if let c = savedChoice {
            use(c, confirmed: false)
            return
        }

        status = embedded?.foundUnsynced == true
            ? "File lyrics aren't time-synced · searching online…"
            : "Finding lyrics…"
        fetchTask = Task { [weak self, provider] in
            guard let self else { return }
            do {
                let found = try await provider.best(for: t)
                guard !Task.isCancelled, self.currentKey == key else { return }
                if let found {
                    self.use(found, confirmed: false)
                    self.persist(found, confirmed: false)
                } else {
                    self.status = "No synced lyrics found"
                }
            } catch {
                guard !Task.isCancelled, self.currentKey == key else { return }
                self.status = Self.describe(error)
            }
        }
    }

    private func use(_ c: LyricsCandidate, confirmed: Bool) {
        candidate = c
        self.confirmed = confirmed
        hidden = false
        lines = LRC.parse(romanize ? Romanizer.convertLRC(c.lrc) : c.lrc, trackEnd: track?.duration ?? 0)
        lineTimedOnly = c.lrc.range(of: "<\\d+:\\d+", options: .regularExpression) == nil
        status = lines.isEmpty ? "These lyrics have no timing" : "Lyrics loaded"
        pushToPhone(full: true)
        refresh()
    }

    // MARK: - Tick / cross / change

    /// "Correct"
    func confirmCurrent() {
        guard let c = candidate else { return }
        confirmed = true
        persist(c, confirmed: true)
    }

    /// "Wrong" / "Change…": list other lyrics for this song.
    func openPicker() {
        showPicker = true
        pickerMessage = ""
        refreshAlternatives()
        if !alternatives.contains(where: { $0.id.hasPrefix("lrclib:") }) { searchOnline() }
    }

    func closePicker() {
        showPicker = false
        alternatives = []
    }

    /// Prepares the "Search manually" window: lists what's known and searches online if needed.
    func openFinder() { openPicker() }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Search LRCLIB. Pass a different title/artist to override what the player reports.
    func searchOnline(title: String? = nil, artist: String? = nil) {
        guard let t = track, !searching, !currentKey.isEmpty else { return }
        var query = t
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { query.title = title }
        if let artist { query.artist = artist.trimmingCharacters(in: .whitespaces) }   // may be empty: title-only search
        query.album = (title == nil && artist == nil) ? t.album : ""
        let exact = title != nil || artist != nil        // typed by the user: search it as written

        let key = currentKey
        searching = true
        pickerMessage = ""
        searchTask?.cancel()
        searchTask = Task { [weak self, provider] in
            guard let self else { return }
            defer { self.searching = false }
            do {
                let found = try await provider.alternatives(for: query, exact: exact)
                guard !Task.isCancelled, self.currentKey == key else { return }
                self.pickerMessage = found.isEmpty ? "No synced lyrics found online" : ""
                self.searchSummary = "\(found.count) result(s) for “\(query.title)” – \(query.artist)"
                var e = self.cache.entry(for: key)
                    ?? CacheEntry(chosenID: "", confirmed: false, candidates: [], rejected: [])
                e.candidates = self.merge(e.candidates, found)
                self.cache.set(e, for: key)
                self.refreshAlternatives()
            } catch {
                guard !Task.isCancelled, self.currentKey == key else { return }
                self.pickerMessage = Self.describe(error)
            }
        }
    }

    /// Pick one from the list. Saved as confirmed; the previous choice is remembered as wrong.
    func choose(_ c: LyricsCandidate) {
        let old = candidate?.id
        setOffsetQuietly(0)
        use(c, confirmed: true)
        persist(c, confirmed: true, rejecting: old)
        closePicker()
    }

    /// Save text edited by hand as this song's lyrics. The earlier version stays in the list.
    func saveEdited(_ text: String) {
        guard !currentKey.isEmpty else { return }
        let c = LyricsCandidate(id: "custom", label: "Edited by you", lrc: text, duration: nil)
        use(c, confirmed: true)
        persist(c, confirmed: true)
    }

    /// "None of these": hide lyrics for this song from now on.
    func hideLyrics() {
        guard !currentKey.isEmpty else { return }
        var e = cache.entry(for: currentKey)
            ?? CacheEntry(chosenID: Self.noneID, confirmed: true, candidates: [], rejected: [])
        if let old = candidate?.id, !e.rejected.contains(old) { e.rejected.append(old) }
        e.chosenID = Self.noneID
        e.confirmed = true
        cache.set(e, for: currentKey)

        candidate = nil
        lines = []
        hidden = true
        confirmed = true
        status = "Lyrics hidden for this song"
        closePicker()
        pushToPhone(full: true)
        refresh()
    }

    func clearCache() { cache.clear() }

    /// Shows the overlay for a few seconds even when it would normally only appear on the lock screen.
    func previewOnScreen() {
        guard !lines.isEmpty else { return }
        previewing = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.previewing = false
        }
    }

    // MARK: - Writing lyrics to files

    /// Writes the current lyrics into the song file (MP3, FLAC, M4A). Asks first, keeps a backup.
    func embedInFile() {
        guard let c = candidate, let path = localPath else { return }
        guard LRC.isSynced(c.lrc) else { fileMessage = "Only time-synced lyrics can be embedded."; return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let ok = confirm(
            "Write these lyrics into “\(name)”?",
            info: "The lyrics are saved inside the file as timed (LRC) text. The audio is not touched. "
                + "A one-time backup of the original goes to ~/Library/Application Support/NekoLyrics/Backups. "
                + "Note: the Music app's own Lyrics panel may show the timestamps as plain text.",
            ok: "Embed")
        guard ok else { return }

        fileMessage = "Writing…"
        let lrc = c.lrc
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result { try TagWriter.embed(lrc: lrc, intoFileAt: path) }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                self.fileMessage = "Embedded in “\(name)”. Original backed up."
            case .failure(let error):
                self.fileMessage = "Couldn't embed: \(error.localizedDescription)"
            }
        }
    }

    /// Saves song.lrc next to the song file: no change to the file itself.
    func saveSidecarFile() {
        guard let c = candidate, let path = localPath else { return }
        let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("lrc")
        if FileManager.default.fileExists(atPath: url.path),
           !confirm("Replace “\(url.lastPathComponent)”?", info: "A file with that name already exists next to the song.", ok: "Replace") {
            return
        }
        do {
            try TagWriter.saveSidecar(lrc: c.lrc, to: url)
            fileMessage = "Saved \(url.lastPathComponent) next to the song."
        } catch {
            fileMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func confirm(_ message: String, info: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Cache plumbing

    private func refreshAlternatives() {
        var list: [LyricsCandidate] = []
        if let p = localPath {                       // re-scan the file: picks up tag edits
            list += EmbeddedLyrics.read(path: p).candidates
        }
        let saved = cache.entry(for: currentKey)
        for c in saved?.candidates ?? [] where !list.contains(where: { $0.id == c.id }) {
            list.append(c)
        }
        let rejected = Set(saved?.rejected ?? [])
        func rank(_ c: LyricsCandidate) -> Int {
            rejected.contains(c.id) ? 3 : (c.id.hasPrefix("apple:") ? 0 : (c.id.hasPrefix("lrclib:") ? 2 : 1))
        }
        alternatives = list
            .filter { $0.id != candidate?.id }
            .enumerated()
            .sorted { a, b in
                rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
            }
            .map { $0.element }
    }

    private func persist(_ chosen: LyricsCandidate, confirmed: Bool,
                         extras: [LyricsCandidate] = [], rejecting old: String? = nil) {
        guard !currentKey.isEmpty else { return }
        var e = cache.entry(for: currentKey)
            ?? CacheEntry(chosenID: chosen.id, confirmed: confirmed, candidates: [], rejected: [])
        e.chosenID = chosen.id
        e.confirmed = confirmed
        e.candidates = merge(e.candidates, [chosen] + extras)
        if let old, old != chosen.id, old != Self.noneID, !e.rejected.contains(old) { e.rejected.append(old) }
        e.rejected.removeAll { $0 == chosen.id }
        if confirmed { e.songOffset = abs(offset) < 0.001 ? nil : offset }
        cache.set(e, for: currentKey)
    }

    private func merge(_ existing: [LyricsCandidate], _ new: [LyricsCandidate]) -> [LyricsCandidate] {
        var out = existing
        for c in new {
            if let i = out.firstIndex(where: { $0.id == c.id }) { out[i] = c } else { out.append(c) }
        }
        return out
    }

    // MARK: - Phone + overlay

    private func pushToPhone(full: Bool) {
        if full {
            let wire = lines.map { line in
                WireLine(words: line.words.map { WireWord(text: $0.text, start: $0.start, end: $0.end) },
                         start: line.start)
            }
            phone.send(.lyrics(title: track?.title ?? "", artist: track?.artist ?? "", lines: wire))
        }
        phone.send(.clock(isPlaying: isPlaying, position: currentTime))
    }

    private func refresh() {
        // While previewing, show even when paused or when "only on lock screen" is on.
        // On the lock screen things stay up when you pause, so you can press play again.
        let visible = ((lyricsEnabled && !lines.isEmpty) || edgeLight)
            && (previewing || ((isPlaying || isLocked) && (!lockedOnly || isLocked)))
        let lockUI: Bool = isLocked && track != nil
        if visible || lockUI { overlay.show() } else { overlay.hide() }
        desktop.syncLockPlayer(show: lockUI && showLockPlayer)
        desktop.syncWallpaper(show: liveWallpaper && isPlaying)
        if visible && isPlaying { awake.enable() } else { awake.disable() }
    }
}
