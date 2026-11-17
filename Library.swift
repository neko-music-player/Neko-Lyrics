import AppKit
import ImageIO
import SwiftUI

// MARK: - Models

struct Album: Identifiable, Equatable {
    let id: String
    let name: String
    let artist: String
    let year: String
    let art: URL?
    let link: URL?
    var local: Bool = false      // from your own Music library (cover read from the app)
}

struct SongHit: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let art: URL?
    let link: URL?
    var persistentID: String? = nil
}

struct QueueItem: Identifiable, Equatable {
    let id: Int          // 1-based position in the playing playlist
    let title: String
    let artist: String
}

private struct ITunesResponse: Decodable { let results: [ITunesItem] }

private struct ITunesItem: Decodable {
    let collectionId: Int?
    let collectionName: String?
    let trackId: Int?
    let trackName: String?
    let artistName: String?
    let artworkUrl100: String?
    let collectionViewUrl: String?
    let trackViewUrl: String?
    let releaseDate: String?
}

/// Runs a small AppleScript and returns its text result (nil on error).
enum AlbumSource: String, CaseIterable, Identifiable {
    case library, store
    var id: String { rawValue }
    var title: String { self == .library ? "My library" : "Store" }
}

enum Script {
    /// Same, but safe to call off the main thread (used for big library queries).
    nonisolated static func runBackground(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    nonisolated static func quote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Items of an AppleScript list result as strings.
    nonisolated static func strings(_ d: NSAppleEventDescriptor?) -> [String] {
        guard let d, d.numberOfItems > 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(d.numberOfItems)
        for i in 1...d.numberOfItems { out.append(d.atIndex(i)?.stringValue ?? "") }
        return out
    }

    @MainActor
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }
}

// MARK: - Library: albums, search, queue and player state for the desktop player

/// Albums and song search come from Apple's public iTunes Search API (no account or key).
/// The queue and the shuffle / repeat / volume controls talk to the Music or Spotify app.
@MainActor
final class Library: ObservableObject {
    @Published var albums: [Album] = []
    @Published var albumsArtist = ""
    @Published var center = 0
    @Published var results: [SongHit] = []
    @Published var searching = false
    @Published var searchMessage = ""
    @Published var queue: [QueueItem] = []
    @Published var queueMessage = ""
    @Published var localArt: [String: NSImage] = [:]
    @Published var albumSource: AlbumSource = AlbumSource(rawValue: UserDefaults.standard.string(forKey: "albumSource") ?? "") ?? .library {
        didSet {
            UserDefaults.standard.set(albumSource.rawValue, forKey: "albumSource")
            albumsArtist = ""
            if !lastArtist.isEmpty { loadAlbums(for: lastArtist) }
        }
    }
    @Published var volume: Double = 0.5
    @Published var shuffle = false
    @Published var repeating = false

    /// Set by the engine: which player is active right now.
    var currentSource: () -> Source? = { nil }

    private var lastArtist = ""
    private var allLocal: [Album] = []
    private var volumeTask: Task<Void, Never>?
    private var lastVolumeSet = Date.distantPast
    private var artLoading = Set<String>()
    private var artQueue: [Album] = []
    private var artBusy = false
    private var albumTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var timer: Timer?
    private var ticks = 0

    // MARK: iTunes Search

    private static func makeURL(_ params: [String: String]) -> URL? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps?.url
    }

    private static func artwork(_ raw: String?, size: Int) -> URL? {
        guard let raw else { return nil }
        return URL(string: raw.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb"))
    }

    private static func fetch(_ params: [String: String]) async -> [ITunesItem] {
        guard let endpoint = makeURL(params) else { return [] }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(ITunesResponse.self, from: data) else { return [] }
        return decoded.results
    }

    /// Albums for the playing artist: from your own Music library (default) or the online catalog.
    func loadAlbums(for rawArtist: String) {
        let artist: String = QueryCleaner.artist(rawArtist)
        guard !artist.isEmpty, artist != albumsArtist else { return }
        lastArtist = rawArtist
        albumsArtist = artist
        albumTask?.cancel()
        if albumSource == .library, NowPlayingMonitor.isRunning(.music) {
            loadLocalAlbums(artist: artist)
        } else {
            loadStoreAlbums(artist: artist)
        }
    }

    /// Albums from the Music app's library: the artist's own albums first, then the rest of the library.
    /// The library is read from Music once and cached; later song changes only re-order it (instant).
    private func loadLocalAlbums(artist: String) {
        if !allLocal.isEmpty {
            arrange(artist: artist)
            return
        }
        albumTask = Task { [weak self] in
            let all: [Album] = await Task.detached(priority: .userInitiated) { () -> [Album] in
                let albumsD = Script.runBackground("tell application \"Music\" to return album of every track of library playlist 1")
                let artistsD = Script.runBackground("tell application \"Music\" to return artist of every track of library playlist 1")
                let yearsD = Script.runBackground("tell application \"Music\" to return year of every track of library playlist 1")
                let names = Script.strings(albumsD)
                let artists = Script.strings(artistsD)
                let years = Script.strings(yearsD)
                guard !names.isEmpty, names.count == artists.count else { return [] }
                var out: [Album] = []
                var seen = Set<String>()
                for i in names.indices {
                    let name = names[i]
                    if name.isEmpty { continue }
                    let id = "local:" + name.lowercased()
                    if seen.contains(id) { continue }
                    seen.insert(id)
                    let year = i < years.count ? years[i] : ""
                    out.append(Album(id: id, name: name, artist: artists[i], year: year == "0" ? "" : year,
                                     art: nil, link: nil, local: true))
                }
                return out
            }.value
            guard !Task.isCancelled, let self else { return }
            if all.isEmpty {
                self.loadStoreAlbums(artist: artist)        // not in your library: use the catalog
                return
            }
            self.allLocal = all
            self.arrange(artist: self.albumsArtist)
        }
    }

    private func arrange(artist: String) {
        let key: String = artist.lowercased()
        var mine: [Album] = []
        var others: [Album] = []
        for album in allLocal {
            if album.artist.lowercased().contains(key) { mine.append(album) } else if others.count < 60 { others.append(album) }
        }
        mine.sort { $0.year > $1.year }
        let list: [Album] = mine + others
        if list.isEmpty { loadStoreAlbums(artist: artist); return }
        albums = list
        center = 0
    }

    /// Reads one album's cover from the Music app (cached), on demand.
    func playAlbum(_ album: Album) {
        guard album.local else { openAlbum(album); return }
        Task.detached(priority: .userInitiated) {
            _ = Script.runBackground("tell application \"Music\" to play (first track of library playlist 1 whose album is \"\(Script.quote(album.name))\")")
        }
    }

    /// Covers are loaded one at a time (newest request first, so the cover you are looking at wins) and
    /// shrunk to thumbnails. Parallel AppleScript calls were what made scrolling stutter.
    func ensureArt(_ album: Album) {
        guard album.local, localArt[album.id] == nil, !artLoading.contains(album.id) else { return }
        artLoading.insert(album.id)
        artQueue.append(album)
        pumpArt()
    }

    private func pumpArt() {
        guard !artBusy, let album = artQueue.popLast() else { return }
        artBusy = true
        let name: String = album.name
        Task { [weak self] in
            let data: Data? = await Task.detached(priority: .utility) { () -> Data? in
                let src = "tell application \"Music\" to return data of artwork 1 of (first track of library playlist 1 whose album is \"\(Script.quote(name))\")"
                return Script.runBackground(src)?.data
            }.value
            guard let self else { return }
            if let data, let image = Library.thumbnail(data, maxPixel: 420) { self.localArt[album.id] = image }
            self.artLoading.remove(album.id)
            self.artBusy = false
            self.pumpArt()
        }
    }

    private static func thumbnail(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Local album: shows it in the Music app and leaves your queue alone. Playing it (which, like in
    /// Music itself, replaces the queue) is a separate, explicit action.
    func openAlbum(_ album: Album) {
        if album.local {
            _ = Script.run("tell application \"Music\" to reveal (first track of library playlist 1 whose album is \"\(Script.quote(album.name))\")")
        } else {
            open(link: album.link, searchText: album.name + " " + album.artist)
        }
    }

    private func loadStoreAlbums(artist: String) {
        albumTask?.cancel()
        albumTask = Task { [weak self] in
            let items = await Library.fetch(["term": artist, "entity": "album", "limit": "50", "media": "music"])
            guard !Task.isCancelled, let self else { return }
            let key: String = artist.lowercased()
            var list: [Album] = []
            var seen = Set<String>()
            for i in items {
                guard let id = i.collectionId, let name = i.collectionName, let who = i.artistName,
                      who.lowercased().contains(key), !seen.contains(name.lowercased()) else { continue }
                seen.insert(name.lowercased())
                let year: String = String((i.releaseDate ?? "").prefix(4))
                let link: URL? = i.collectionViewUrl.flatMap { URL(string: $0) }
                list.append(Album(id: String(id), name: name, artist: who, year: year,
                                  art: Library.artwork(i.artworkUrl100, size: 600), link: link))
            }
            list.sort { $0.year > $1.year }
            self.albums = list
            self.center = 0
        }
    }

    func search(_ query: String) {
        let q: String = query.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        guard !q.isEmpty else { clearSearch(); return }
        searching = true
        searchMessage = ""
        if albumSource == .library, NowPlayingMonitor.isRunning(.music) {
            searchLocal(q)
            return
        }
        searchTask = Task { [weak self] in
            let items = await Library.fetch(["term": q, "entity": "song", "limit": "25", "media": "music"])
            guard !Task.isCancelled, let self else { return }
            var hits: [SongHit] = []
            for i in items {
                guard let id = i.trackId, let title = i.trackName else { continue }
                let link: URL? = i.trackViewUrl.flatMap { URL(string: $0) }
                hits.append(SongHit(id: String(id), title: title, artist: i.artistName ?? "",
                                    album: i.collectionName ?? "",
                                    art: Library.artwork(i.artworkUrl100, size: 120), link: link))
            }
            self.results = hits
            self.searching = false
            self.searchMessage = hits.isEmpty ? "Nothing found (or you are offline)." : ""
        }
    }

    /// Searches your own Music library (Music's own index, so it is fast), not the online catalog.
    private func searchLocal(_ q: String) {
        let src = """
        tell application "Music"
            try
                set found to search library playlist 1 for "\(Script.quote(q))"
                set out to ""
                set n to count of found
                if n > 30 then set n to 30
                repeat with i from 1 to n
                    set t to item i of found
                    set out to out & (persistent ID of t) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & linefeed
                end repeat
                return out
            on error
                return ""
            end try
        end tell
        """
        searchTask = Task { [weak self] in
            let text: String = await Task.detached(priority: .userInitiated) {
                Script.runBackground(src)?.stringValue ?? ""
            }.value
            guard !Task.isCancelled, let self else { return }
            var hits: [SongHit] = []
            for row in text.components(separatedBy: "\n") {
                let p: [String] = row.components(separatedBy: "||")
                guard p.count >= 4, !p[0].isEmpty else { continue }
                hits.append(SongHit(id: p[0], title: p[1], artist: p[2], album: p[3], art: nil, link: nil, persistentID: p[0]))
            }
            self.results = hits
            self.searching = false
            self.searchMessage = hits.isEmpty ? "Nothing in your library matches." : ""
        }
    }

    // MARK: Queue without clearing it

    @Published var openedAlbum: Album?
    @Published var albumTracks: [SongHit] = []
    @Published var queueNotice = ""
    private var noticeTask: Task<Void, Never>?

    private func notice(_ text: String) {
        queueNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            self?.queueNotice = ""
        }
    }

    /// Opens a library album as a list of songs.
    func showAlbum(_ album: Album) {
        guard album.local else { openAlbum(album); return }
        openedAlbum = album
        albumTracks = []
        let name: String = Script.quote(album.name)
        let src = """
        tell application "Music"
            try
                set ts to (every track of library playlist 1 whose album is "\(name)")
                set out to ""
                repeat with t in ts
                    set out to out & (persistent ID of t) & "||" & (name of t) & "||" & (artist of t) & "||" & (disc number of t) & "||" & (track number of t) & linefeed
                end repeat
                return out
            on error
                return ""
            end try
        end tell
        """
        Task { [weak self] in
            let text: String = await Task.detached(priority: .userInitiated) {
                Script.runBackground(src)?.stringValue ?? ""
            }.value
            guard let self, self.openedAlbum?.id == album.id else { return }
            var rows: [(disc: Int, no: Int, hit: SongHit)] = []
            for row in text.components(separatedBy: "\n") {
                let p: [String] = row.components(separatedBy: "||")
                guard p.count >= 5, !p[0].isEmpty else { continue }
                let hit = SongHit(id: p[0], title: p[1], artist: p[2], album: album.name, art: nil, link: nil, persistentID: p[0])
                rows.append((Int(p[3]) ?? 1, Int(p[4]) ?? 0, hit))
            }
            rows.sort { $0.disc != $1.disc ? $0.disc < $1.disc : $0.no < $1.no }
            self.albumTracks = rows.map { $0.hit }
        }
    }

    /// Adds a whole album to the queue straight from the cover (no need to open it first).
    func addAlbumToQueue(_ album: Album, next: Bool = true) {
        guard album.local else { openAlbum(album); return }
        let name: String = Script.quote(album.name)
        let src = """
        tell application "Music"
            try
                set ts to (every track of library playlist 1 whose album is "\(name)")
                set out to ""
                repeat with t in ts
                    set out to out & (persistent ID of t) & "||" & (disc number of t) & "||" & (track number of t) & linefeed
                end repeat
                return out
            on error
                return ""
            end try
        end tell
        """
        Task { [weak self] in
            let text: String = await Task.detached(priority: .userInitiated) {
                Script.runBackground(src)?.stringValue ?? ""
            }.value
            guard let self else { return }
            var rows: [(disc: Int, no: Int, id: String)] = []
            for row in text.components(separatedBy: "\n") {
                let p: [String] = row.components(separatedBy: "||")
                guard p.count >= 3, !p[0].isEmpty else { continue }
                rows.append((Int(p[1]) ?? 1, Int(p[2]) ?? 0, p[0]))
            }
            rows.sort { $0.disc != $1.disc ? $0.disc < $1.disc : $0.no < $1.no }
            if rows.isEmpty { self.notice("No songs found for that album"); return }
            self.addToQueue(rows.map { $0.id }, next: next)
        }
    }

    func closeAlbum() { openedAlbum = nil; albumTracks = [] }

    /// Adds songs to the queue WITHOUT replacing it: right after the current song (`next`) or at the end.
    /// The Music app has no "Up Next" in its scripting, so the first time the rest of the current list is
    /// copied into a playlist called "Neko Lyrics Queue" (playback carries on from the same spot) and
    /// later songs are inserted into that playlist.
    func addToQueue(_ persistentIDs: [String], next: Bool = true) {
        guard !persistentIDs.isEmpty else { return }
        let list: String = persistentIDs.map { "\"\(Script.quote($0))\"" }.joined(separator: ", ")
        let nextFlag: String = next ? "true" : "false"
        let src = """
        tell application "Music"
            try
                set wlName to "Neko Lyrics Queue"
                if not (exists user playlist wlName) then make new user playlist with properties {name:wlName}
                set wlQ to user playlist wlName
                set wlIn to false
                try
                    if (name of current playlist) is wlName then set wlIn to true
                end try
                set wlNote to "Added to your queue"
                if not wlIn then
                    try
                        set wlCur to current track
                        set wlPos to player position
                        set wlPl to current playlist
                        set wlIdx to index of wlCur
                        set wlTotal to count of tracks of wlPl
                        set wlStop to wlIdx + 99
                        if wlStop > wlTotal then set wlStop to wlTotal
                        try
                            delete (every track of wlQ)
                        end try
                        repeat with i from wlIdx to wlStop
                            duplicate (track i of wlPl) to wlQ
                        end repeat
                        play (track 1 of wlQ)
                        set player position to wlPos
                    on error wlErr
                        set wlNote to "Added to the Neko Lyrics Queue playlist (could not continue the current list: " & wlErr & ")"
                    end try
                end if
                set wlCount to count of tracks of wlQ
                set wlHere to 0
                try
                    set wlHere to index of current track
                end try
                repeat with wlID in {\(list)}
                    try
                        set wlT to first track of library playlist 1 whose persistent ID is (wlID as text)
                        duplicate wlT to wlQ
                    end try
                end repeat
                if \(nextFlag) and wlHere > 0 and wlCount > wlHere then
                    -- move the old tail behind the new songs: copy it to the end, then delete the original
                    repeat with i from (wlHere + 1) to wlCount
                        duplicate (track i of wlQ) to wlQ
                    end repeat
                    repeat with i from wlCount to (wlHere + 1) by -1
                        delete (track i of wlQ)
                    end repeat
                end if
                try
                    if player state is stopped then play (track 1 of wlQ)
                end try
                return wlNote
            on error wlMsg
                return "ERR: " & wlMsg
            end try
        end tell
        """
        Task { [weak self] in
            let text: String = await Task.detached(priority: .userInitiated) {
                Script.runBackground(src)?.stringValue ?? ""
            }.value
            guard let self else { return }
            if text.hasPrefix("ERR:") {
                self.notice("Couldn't add: " + text.dropFirst(4))
            } else if text.isEmpty {
                self.notice("Couldn't add: Music didn't accept the script (allow Neko Lyrics under Privacy > Automation > Music)")
            } else {
                self.notice(next ? text.replacingOccurrences(of: "Added to your queue", with: "Playing next") : text)
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.refreshQueue()
        }
    }

    func playLocal(persistentID: String) {
        let src = "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(Script.quote(persistentID))\")"
        Task.detached(priority: .userInitiated) { _ = Script.runBackground(src) }
    }

    func clearSearch() {
        searchTask?.cancel()
        results = []
        searching = false
        searchMessage = ""
    }

    /// Opens an album / song in the player. Apple Music links open in the Music app; for Spotify the
    /// name is searched there (Spotify has no public way to start a specific album from here).
    func open(link: URL?, searchText: String) {
        if currentSource() == .spotify {
            let q: String = searchText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchText
            if let u = URL(string: "spotify:search:" + q) { NSWorkspace.shared.open(u) }
            return
        }
        guard let link else { return }
        var target: URL = link
        if var comps = URLComponents(url: link, resolvingAgainstBaseURL: false),
           comps.host == "music.apple.com" || comps.host == "itunes.apple.com" {
            comps.scheme = "music"
            if let u = comps.url { target = u }
        }
        NSWorkspace.shared.open(target)
    }

    // MARK: Queue (Music app only)

    func refreshQueue() {
        guard currentSource() == .music, NowPlayingMonitor.isRunning(.music) else {
            queue = []
            queueMessage = currentSource() == .spotify ? "Spotify does not share its queue." : "Nothing playing."
            return
        }
        let source = """
        tell application "Music"
            try
                set idx to index of current track
                set total to count of tracks of current playlist
                set stopAt to idx + 24
                if stopAt > total then set stopAt to total
                set out to ""
                repeat with i from idx to stopAt
                    set t to track i of current playlist
                    set out to out & i & "||" & (name of t) & "||" & (artist of t) & linefeed
                end repeat
                return out
            on error
                return ""
            end try
        end tell
        """
        Task { [weak self] in
            // AppleScript runs off the main thread so the interface never stutters.
            let text: String = await Task.detached(priority: .utility) {
                Script.runBackground(source)?.stringValue ?? ""
            }.value
            guard let self else { return }
            var items: [QueueItem] = []
            for row in text.components(separatedBy: "\n") {
                let parts: [String] = row.components(separatedBy: "||")
                guard parts.count >= 3, let n = Int(parts[0]) else { continue }
                items.append(QueueItem(id: n, title: parts[1], artist: parts[2]))
            }
            if items != self.queue { self.queue = items }
            self.queueMessage = items.isEmpty ? "No queue available for this song." : ""
        }
    }

    func play(_ item: QueueItem) {
        _ = Script.run("tell application \"Music\" to play (track \(item.id) of current playlist)")
    }

    // MARK: Shuffle, repeat, volume

    func refreshState() {
        guard let source = currentSource(), NowPlayingMonitor.isRunning(source) else { return }
        let shuffleProp: String = source == .music ? "shuffle enabled" : "shuffling"
        let repeatExpr: String = source == .music ? "(song repeat is not off)" : "repeating"
        let script = "tell application \"\(source.appName)\" to return (sound volume as text) & \"|\" & (\(shuffleProp) as text) & \"|\" & (\(repeatExpr) as text)"
        Task { [weak self] in
            let text: String? = await Task.detached(priority: .utility) {
                Script.runBackground(script)?.stringValue
            }.value
            guard let self, let text else { return }
            let parts: [String] = text.components(separatedBy: "|")
            guard parts.count == 3 else { return }
            // Don't fight the slider while it is being dragged.
            if Date().timeIntervalSince(self.lastVolumeSet) > 3, let v = Double(parts[0]) {
                self.volume = min(max(v / 100.0, 0), 1)
            }
            self.shuffle = parts[1] == "true"
            self.repeating = parts[2] == "true"
        }
    }

    /// The slider moves instantly; the player is told once the slider has paused for a moment.
    func setVolume(_ v: Double) {
        volume = v
        lastVolumeSet = Date()
        volumeTask?.cancel()
        guard let source = currentSource() else { return }
        let script = "tell application \"\(source.appName)\" to set sound volume to \(Int(v * 100))"
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { _ = Script.runBackground(script) }.value
        }
    }

    func toggleShuffle() {
        guard let source = currentSource() else { return }
        let prop: String = source == .music ? "shuffle enabled" : "shuffling"
        shuffle.toggle()
        _ = Script.run("tell application \"\(source.appName)\" to set \(prop) to \(shuffle ? "true" : "false")")
    }

    func toggleRepeat() {
        guard let source = currentSource() else { return }
        repeating.toggle()
        if source == .music {
            _ = Script.run("tell application \"Music\" to set song repeat to \(repeating ? "all" : "off")")
        } else {
            _ = Script.run("tell application \"Spotify\" to set repeating to \(repeating ? "true" : "false")")
        }
    }

    // MARK: Following the player

    /// Call when the song changes.
    func trackChanged(_ track: Track) {
        loadAlbums(for: track.artist)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.refreshQueue()
            self?.refreshState()
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                self.refreshState()
                if self.ticks % 4 == 0 { self.refreshQueue() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
