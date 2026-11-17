import Foundation

struct CacheEntry: Codable {
    var chosenID: String            // id of the chosen candidate, or "none" to hide lyrics
    var confirmed: Bool             // user ticked "Correct" or picked it by hand
    var candidates: [LyricsCandidate]
    var rejected: [String]          // candidate ids the user said were wrong
    var songOffset: Double? = nil   // sync offset (seconds) that works for this song, saved when ticked
}

/// Lyrics the user has seen, saved to
/// ~/Library/Application Support/NekoLyrics/lyrics-cache.json so they work offline.
final class LyricsCache {
    private var entries: [String: CacheEntry] = [:]
    private let fileURL: URL

    init() {
        let dir = AppSupport.directory
        fileURL = dir.appendingPathComponent("lyrics-cache.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            entries = decoded
        }
    }

    func entry(for key: String) -> CacheEntry? { entries[key] }

    func set(_ entry: CacheEntry, for key: String) {
        entries[key] = entry
        save()
    }

    func clear() {
        entries = [:]
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}


/// ~/Library/Application Support/NekoLyrics. A folder left by the app's earlier name ("WordLight") is moved over once,
/// so saved lyrics, offsets and backups carry on.
enum AppSupport {
    static var directory: URL {
        let fm = FileManager.default
        let base: URL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir: URL = base.appendingPathComponent("NekoLyrics", isDirectory: true)
        let old: URL = base.appendingPathComponent("WordLight", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
