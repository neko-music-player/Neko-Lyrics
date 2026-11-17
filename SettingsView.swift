import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case lyrics, look, desktop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lyrics: return "Lyrics"
        case .look: return "Look"
        case .desktop: return "Desktop"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @State private var tab: SettingsTab = .lyrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            quickToggles
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { t in Text(t.title).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch tab {
                    case .lyrics: lyricsTab
                    case .look: lookTab
                    case .desktop: desktopTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 440)
            Divider()
            footer
        }
        .padding()
        .frame(width: 360)
    }

    // MARK: Quick toggles: every big feature, one tap

    private var quickToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                quick("Player", "rectangle.stack", $engine.playerOpen)
                quick("Wallpaper", "photo", $engine.liveWallpaper)
                quick("Lyrics", "text.bubble", $engine.lyricsEnabled)
            }
            HStack(spacing: 6) {
                Button { engine.stopEverything() } label: {
                    Label("Stop everything", systemImage: "stop.circle.fill")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("Quit (⌃⌥⌘Q)", systemImage: "power")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 6) {
                quick("Edge light", "rectangle.dashed", $engine.edgeLight)
                quick("Clock", "clock", $engine.showClock)
                quick("Dock icon", "app.badge", $engine.dockIcon)
            }
        }
    }

    private func quick(_ title: String, _ symbol: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.track.map { "\($0.title) — \($0.artist)" } ?? "Nothing playing")
                    .font(.headline)
                    .lineLimit(2)
                Text(engine.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Lyrics: tick / cross, change, file actions

    @ViewBuilder
    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            lyricsSectionBody
            Toggle("Romanize lyrics (Japanese, Korean, Hindi, Nepali, Arabic, Russian…)", isOn: $engine.romanize)
                .font(.caption)
            Toggle("Whole-line effect when a song only has line timing", isOn: $engine.lineModeAuto)
                .font(.caption)
            if engine.lineTimedOnly {
                Text(engine.lineModeAuto ? "This song is line-timed: showing the whole-line effect."
                                         : "This song is line-timed: word effects use estimated timing.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var lyricsSectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine.hidden {
                Text("Lyrics hidden for this song").font(.caption).foregroundStyle(.secondary)
                if !engine.showPicker {
                    Button("Choose lyrics…") { engine.openPicker() }
                }
            } else if let c = engine.candidate {
                Text(c.label).font(.caption.bold()).lineLimit(2)
                if !engine.showPicker {
                    HStack {
                        if engine.confirmed {
                            Label("Confirmed", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Button { engine.confirmCurrent() } label: { Label("Correct", systemImage: "checkmark") }
                        }
                        Button { engine.openPicker() } label: {
                            Label(engine.confirmed ? "Change…" : "Wrong", systemImage: engine.confirmed ? "arrow.triangle.2.circlepath" : "xmark")
                        }
                        Spacer()
                        moreMenu
                    }
                }
            } else {
                HStack {
                    Button("Search for lyrics…") { engine.openPicker() }
                    Button("Search manually…") { LyricsFinder.show(engine: engine) }
                }
            }

            if !engine.fileMessage.isEmpty {
                Text(engine.fileMessage).font(.caption).foregroundStyle(.secondary)
            }
            if engine.showPicker { picker }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Search manually…") { LyricsFinder.show(engine: engine) }
            Button("Edit lyrics text…") { LyricsEditor.show(engine: engine) }
            Divider()
            Button("Embed in song file…") { engine.embedInFile() }
                .disabled(!engine.canWriteToFile)
            Button("Save .lrc next to song…") { engine.saveSidecarFile() }
                .disabled(!engine.canWriteToFile)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var picker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Other lyrics for this song").font(.caption.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.alternatives) { c in row(c) }
                    if engine.searching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Searching online…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if engine.alternatives.isEmpty {
                        Text(engine.pickerMessage.isEmpty ? "Nothing else found" : engine.pickerMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !engine.pickerMessage.isEmpty {
                        Text(engine.pickerMessage).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Button("Search manually…") { LyricsFinder.show(engine: engine) }
                Spacer()
                Button("None of these") { engine.hideLyrics() }
                Button("Cancel") { engine.closePicker() }
            }
            .font(.caption)
        }
    }

    private func row(_ c: LyricsCandidate) -> some View {
        Button { engine.choose(c) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label).font(.caption.bold()).lineLimit(2)
                Text(LRC.preview(c.lrc)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: Tab: Lyrics

    @ViewBuilder
    private var lyricsTab: some View {
        if engine.track != nil {
            lyricsSection
            Divider()
            Text("Lyrics preview").font(.caption.bold())
            LyricsPreview(engine: engine)
            Divider()
            syncSection
        } else {
            Text("Play a song in Spotify or Music.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sync offset, this song: \(engine.offset, specifier: "%+.2f")s")
                .font(.caption)
            Text(engine.confirmed
                 ? "Saved with these lyrics automatically. Next song starts at 0."
                 : "Tick “Correct” to save it with these lyrics. Next song starts at 0.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Lyrics late? Move right. Lyrics early? Move left.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: $engine.offset, in: -3...3, step: 0.05)
        }
    }

    // MARK: Tab: Look

    @ViewBuilder
    private var lookTab: some View {
        Picker("Style", selection: $engine.style) {
            ForEach(LyricStyle.allCases) { s in Text(s.title).tag(s) }
        }
        if engine.style == .stack || engine.style == .stackVisual || engine.style == .random {
            Picker("Stack motion", selection: $engine.stackMotion) {
                ForEach(StackMotion.allCases) { m in Text(m.title).tag(m) }
            }
        }
        Toggle("Random font for each song", isOn: $engine.fontRandom)
        Picker("Font", selection: $engine.fontFamily) {
            ForEach(FontChoices.all) { f in Text(f.name).tag(f.id) }
        }
        Picker("Weight", selection: $engine.fontWeight) {
            ForEach(0..<LyricFont.weights.count, id: \.self) { i in
                Text(LyricFont.weights[i].name).tag(i)
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Text("Text size: \(engine.fontScale, specifier: "%.2f")×").font(.caption)
            Slider(value: $engine.fontScale, in: 0.6...1.6, step: 0.05)
        }

        Divider()
        Picker("Background", selection: $engine.background) {
            ForEach(BackdropMode.allCases) { m in Text(m.title).tag(m) }
        }
        if engine.background == .cover || engine.background == .coverAnimated {
            HStack {
                Text("Soft").font(.caption2)
                Slider(value: $engine.coverSharpness, in: 0...1)
                Text("Sharp").font(.caption2)
            }
            HStack {
                Text("Zoom").font(.caption2)
                Slider(value: $engine.coverZoom, in: 1.0...1.6)
                Text(String(format: "%.2f×", engine.coverZoom)).font(.caption2).monospacedDigit()
            }
            if engine.background == .coverAnimated {
                HStack {
                    Text("Drift").font(.caption2)
                    Slider(value: $engine.coverMotion, in: 0...1)
                }
            }
        }
        if engine.background.usesCover && engine.albumImage == nil && engine.track != nil {
            Text("Cover art not found yet for this song.").font(.caption).foregroundStyle(.secondary)
        }
        Picker("Album card beside lyrics", selection: $engine.artwork) {
            ForEach(ArtworkMode.allCases) { m in Text(m.title).tag(m) }
        }
        if (engine.artwork == .animated || engine.background == .fullArtwork || engine.liveWallpaper), engine.track != nil {
            HStack {
                Button(engine.videoURL == nil ? "Use my video loop…" : "Change video…") { engine.chooseVideo() }
                if engine.videoURL != nil {
                    Button("Remove video") { engine.removeVideo() }
                }
            }
            .font(.caption)
            Text(engine.videoURL == nil
                 ? "Without a video, the cover is animated (drift, sway, glow)."
                 : "Playing your video for this song.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        Divider()
        Toggle("Auto Sync colors from album art", isOn: $engine.autoSync)
        if engine.autoSync && engine.albumPalette == nil && engine.track != nil {
            Text("No album art found for this song, using your colors.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if engine.autoSync && engine.albumPalette != nil {
            Text("Picking a color below turns Auto Sync off.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        SwatchRow(title: "Lyric (sung words)", color: $engine.lyricColor, onPick: { engine.autoSync = false })
        SwatchRow(title: "Highlight (current word)", color: $engine.highlightColor, onPick: { engine.autoSync = false })

        Divider()
        Toggle("Edge light (glowing screen border)", isOn: $engine.edgeLight)
        if engine.edgeLight {
            VStack(alignment: .leading, spacing: 2) {
                Text("Thickness").font(.caption2)
                Slider(value: $engine.edgeThickness, in: 4...40)
                Text("Glow").font(.caption2)
                Slider(value: $engine.edgeGlow, in: 0.2...1.0)
                Text("Corner radius").font(.caption)
                Slider(value: $engine.edgeRadius, in: 0...60)
            }
        }

        Button("Preview on screen (10 s)") { engine.previewOnScreen() }
            .disabled(engine.lines.isEmpty)
    }

    // MARK: Tab: Desktop

    @ViewBuilder
    private var desktopTab: some View {
        Toggle("Desktop player (albums, queue, search)", isOn: $engine.playerOpen)
        if engine.playerOpen {
            Picker("Player sits", selection: $engine.playerLevel) {
                ForEach(PlayerLevel.allCases) { l in Text(l.title).tag(l) }
            }
            if engine.playerLevel == .desktop {
                Text("Behind apps the search box may not take typing. Use “Like a normal window” to type.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        Toggle("Lyrics on screen", isOn: $engine.lyricsEnabled)
        Toggle("Draw lyrics above all apps", isOn: $engine.lyricsAboveApps)
        Text("Off: lyrics sit on the desktop (or inside the player) and never cover your work. The lock screen always shows them.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Toggle("Live wallpaper while playing", isOn: $engine.liveWallpaper)
        if engine.liveWallpaper && engine.background == .transparent {
            Text("Background is Transparent, so the wallpaper stays off. Pick another Background to use it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        if engine.liveWallpaper {
            Toggle("Big clock on the wallpaper", isOn: $engine.showClock)
        }
        Toggle("Dock icon: cover with a beating ring", isOn: $engine.dockIcon)
        Toggle("Full player on the lock screen", isOn: $engine.showLockPlayer)
        Toggle("Allow dragging the player (off keeps sliders reliable)", isOn: $engine.playerDraggable)
        Toggle("Show music controls, search and queue (desktop and lock screen)", isOn: $engine.showControls)
        Toggle("Album browser on the desktop player", isOn: $engine.showAlbumBrowser)
        Toggle("Album browser on the lock screen", isOn: $engine.lockAlbumBrowser)
        PlaylistOptions(library: engine.library)

        Divider()
        Toggle("Only on lock screen", isOn: $engine.lockedOnly)
        Text(LockScreenLayer.shared.available
             ? "Lock screen display: supported on this Mac. Lock with Control-Command-Q to test."
             : "Lock screen display: not available on this macOS version (shows on the desktop only).")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Button("Show lock-screen log in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([LockScreenLayer.logURL])
        }
        .font(.caption)
        Toggle("Controls bar only (lock screen, if the full player is off)", isOn: $engine.showWidget)
        if engine.showWidget {
            VStack(alignment: .leading, spacing: 2) {
                Text("Widget height (keep it above “Touch ID or Enter Password”)").font(.caption2)
                Slider(value: $engine.widgetFraction, in: 0.08...0.7)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Clear lyrics cache") { engine.clearCache() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.caption)
    }
}

/// Scrolling list of the loaded lyrics. The line being sung is highlighted and kept in view.
struct LyricsPreview: View {
    @ObservedObject var engine: Engine

    var body: some View {
        if engine.lines.isEmpty {
            Text("No lyrics loaded yet").font(.caption).foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let active = engine.lineIndex(at: engine.currentTime)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(engine.lines.indices, id: \.self) { i in
                                let line = engine.lines[i]
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(timeLabel(line.start))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Text(line.words.map { $0.text }.joined(separator: " "))
                                        .font(i == active ? .callout.bold() : .callout)
                                        .foregroundStyle(i == active ? Color.accentColor : Color.secondary)
                                }
                                .id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 170)
                    .onChange(of: active) { _, new in
                        if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
                    }
                }
            }
        }
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}


/// Inline color picker (saturation/brightness square, hue bar, quick swatches). The system color panel
/// opens as a floating window in an odd place and closes the menu, so everything is drawn right here.
struct SwatchRow: View {
    let title: String
    @Binding var color: Color
    var onPick: () -> Void = {}

    @State private var open = false
    @State private var hue: Double = 0
    @State private var sat: Double = 0
    @State private var bri: Double = 1

    private let swatches: [Color] = [
        .white, Color(red: 1, green: 0.85, blue: 0.3), .orange, Color(red: 1, green: 0.4, blue: 0.5), .pink,
        .purple, Color(red: 0.4, green: 0.6, blue: 1), .cyan, .mint, .green
    ]

    private func push() {
        color = Color(hue: hue, saturation: sat, brightness: bri)
        onPick()
    }

    private func load() {
        let v = color.hsb
        hue = v.h; sat = v.s; bri = v.b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if !open { load() }
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                    Text(title).font(.caption)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                square
                hueBar
                HStack(spacing: 5) {
                    ForEach(0..<swatches.count, id: \.self) { i in
                        Button {
                            color = swatches[i]
                            load()
                            onPick()
                        } label: {
                            Circle().fill(swatches[i]).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var square: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                Circle().stroke(Color.white, lineWidth: 2)
                    .background(Circle().stroke(Color.black.opacity(0.4), lineWidth: 3.5))
                    .frame(width: 12, height: 12)
                    .position(x: g.size.width * sat, y: g.size.height * (1 - bri))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                sat = min(max(v.location.x / max(g.size.width, 1), 0), 1)
                bri = 1 - min(max(v.location.y / max(g.size.height, 1), 0), 1)
                push()
            })
        }
        .frame(height: 110)
    }

    private var hueBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                LinearGradient(colors: (0...12).map { Color(hue: Double($0) / 12.0, saturation: 1, brightness: 1) },
                               startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule())
                Circle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, g.size.width - 14) * hue)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hue = min(max(v.location.x / max(g.size.width, 1), 0), 1)
                push()
            })
        }
        .frame(height: 14)
    }
}

struct PlaylistOptions: View {
    @ObservedObject var library: Library

    var body: some View {
        Toggle("Use helper playlists for queue and Play album", isOn: $library.usePlaylists)
        Text("Apple Music can't be queued from outside, so Neko Lyrics fills two playlists named \"Neko Lyrics Queue\" and \"Neko Lyrics Album\". Off: no playlists, Play album plays the first song only.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Button("Delete the helper playlists") { library.removeHelperPlaylists() }
            .font(.caption)
    }
}
