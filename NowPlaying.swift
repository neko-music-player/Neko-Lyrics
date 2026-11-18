import AppKit

/// Watches Spotify and Apple Music. Both apps post distributed notifications on
/// track/state changes; playback position is read via AppleScript (needs the
/// Automation permission, see NSAppleEventsUsageDescription in Info.plist).
///
/// Notifications only fire on CHANGES, so on launch (and whenever nothing is known)
/// the monitor also asks the players directly what is playing.
@MainActor
final class NowPlayingMonitor {
    struct Snapshot {
        var track: Track?
        var isPlaying: Bool
        /// nil when the player could not be asked (the caller keeps its own clock running).
        var position: TimeInterval?
    }

    var onChange: ((Snapshot) -> Void)?

    private var timer: Timer?
    private var current: Track?
    private var playing = false

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.handle(n.userInfo, source: .spotify) }
        }
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.handle(n.userInfo, source: .music) }
        }
        bootstrap()
        // Re-anchor the clock regularly so interpolation never drifts far.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.resync() }
        }
    }

    private func handle(_ info: [AnyHashable: Any]?, source: Source) {
        guard let info else { return }
        let state = info["Player State"] as? String ?? ""
        let title = info["Name"] as? String ?? ""
        playing = (state == "Playing")
        if state == "Stopped" || title.isEmpty {
            current = nil
        } else {
            let ms = (info["Duration"] as? NSNumber)?.doubleValue
                ?? (info["Total Time"] as? NSNumber)?.doubleValue ?? 0
            current = Track(
                title: title,
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? "",
                duration: ms / 1000,
                source: source
            )
        }
        publish()
    }

    private var idleTicks = 0

    private func resync() {
        if current == nil { bootstrap(); return }
        guard playing else {
            // Paused: the "now playing" notification can be missed (sleep, lock, a long pause), which left the app
            // thinking nothing was playing. Quietly ask the player every few seconds instead of trusting it.
            idleTicks += 1
            if idleTicks >= 3 { idleTicks = 0; bootstrap() }
            return
        }
        idleTicks = 0
        publish()
    }

    /// Ask again right now (after wake-up, unlock, a screen change).
    func refreshNow() { bootstrap() }

    /// Ask the players what is playing right now (used at launch and while nothing is known).
    private func bootstrap() {
        guard let now = Self.readCurrent() else { return }
        current = now.track
        playing = now.isPlaying
        onChange?(Snapshot(track: now.track, isPlaying: now.isPlaying, position: now.position))
    }

    private func publish() {
        let pos = current.flatMap { Self.position(of: $0.source) }
        onChange?(Snapshot(track: current, isPlaying: playing, position: pos))
    }

    // MARK: - Asking the players

    static func position(of source: Source) -> TimeInterval? {
        // Never talk to an app that isn't running: AppleScript would launch it.
        guard isRunning(source) else { return nil }
        let script = NSAppleScript(source: "tell application \"\(source.appName)\" to return player position")
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil,
              let s = result.stringValue else { return nil }
        return Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// The track currently loaded in Music or Spotify (a playing one wins over a paused one).
    static func readCurrent() -> (track: Track, isPlaying: Bool, position: TimeInterval)? {
        var paused: (track: Track, isPlaying: Bool, position: TimeInterval)?
        for source in [Source.music, Source.spotify] {
            guard isRunning(source), let r = read(source) else { continue }
            if r.isPlaying { return r }
            if paused == nil { paused = r }
        }
        return paused
    }

    private static func read(_ source: Source) -> (track: Track, isPlaying: Bool, position: TimeInterval)? {
        let src = """
        tell application "\(source.appName)"
            if player state is stopped then return ""
            set t to current track
            return (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (duration of t as text) & "||" & (player position as text) & "||" & (player state as text)
        end tell
        """
        var error: NSDictionary?
        guard let s = NSAppleScript(source: src)?.executeAndReturnError(&error).stringValue,
              error == nil, !s.isEmpty else { return nil }
        let parts = s.components(separatedBy: "||")
        guard parts.count == 6, !parts[0].isEmpty else { return nil }

        func number(_ x: String) -> Double { Double(x.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        var duration = number(parts[3])
        if source == .spotify { duration /= 1000 }          // Spotify reports milliseconds
        let isPlaying = parts[5].lowercased().contains("playing") || parts[5].contains("kPSP")
        let track = Track(title: parts[0], artist: parts[1], album: parts[2], duration: duration, source: source)
        return (track, isPlaying, number(parts[4]))
    }

    /// POSIX path of the file the Music app is playing, or nil for streamed tracks.
    /// (Spotify exposes no file path, so embedded lyrics only work with Music.)
    static func filePath(for source: Source) -> String? {
        guard source == .music, isRunning(source) else { return nil }
        let script = NSAppleScript(source: "tell application \"Music\" to return POSIX path of (get location of current track)")
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil,
              let path = result.stringValue, !path.isEmpty else { return nil }
        return path
    }

    /// "playpause", "next track" or "previous track" for the running player. Does not launch it.
    static func transport(_ command: String, source: Source) {
        guard isRunning(source) else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"\(source.appName)\" to \(command)")?.executeAndReturnError(&error)
    }

    /// Jump to a position (seconds) in the running player.
    static func seek(to seconds: TimeInterval, source: Source) {
        guard isRunning(source) else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"\(source.appName)\" to set player position to \(seconds)")?.executeAndReturnError(&error)
    }

    static func isRunning(_ source: Source) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }
}
