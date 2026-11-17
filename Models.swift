import Foundation

enum Source: String {
    case spotify, music

    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var appName: String { self == .spotify ? "Spotify" : "Music" }
}

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var source: Source

    /// Identity used for the lyrics cache.
    var key: String {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        return "\(norm(artist))|\(norm(title))|\(norm(album))"
    }
}

struct Word: Identifiable {
    let id = UUID()
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// Icon shown by the "Visual" styles, looked up once when the lyrics are parsed.
    let glyph: Glyph?

    init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
        self.glyph = WordGlyphs.glyph(for: text)
    }
}

struct Line: Identifiable {
    let id = UUID()
    let words: [Word]
    let start: TimeInterval
    let end: TimeInterval
}

/// One possible set of lyrics for a song. Everything is stored as LRC text
/// (standard or "enhanced" with per-word <mm:ss.xx> tags) and parsed on load.
struct LyricsCandidate: Codable, Identifiable, Equatable {
    var id: String          // "embedded:uslt0", "sidecar", "lrclib:12345", "custom"
    var label: String       // shown in the menu
    var lrc: String
    var duration: Double?   // length of the recording these lyrics were timed for
}
