import Foundation

/// Online lyrics sources. A word-level provider can be added by conforming to this.
protocol LyricsProvider {
    /// The single best match, or nil. Throws only on network problems.
    func best(for track: Track) async throws -> LyricsCandidate?
    /// Other possible matches, most plausible first. `exact` = search the text as typed,
    /// without stripping "(feat. …)", "- Remastered 2011" and second artists.
    func alternatives(for track: Track, exact: Bool) async throws -> [LyricsCandidate]
}

enum LyricsError: LocalizedError {
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "The lyrics service returned an error (HTTP \(code))."
        case .network(let why): return "Couldn't reach the lyrics service: \(why)"
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Players report titles like "Song (feat. X) - Remastered 2011" and artists like "A, B & C".
/// LRCLIB search needs every phrase to match, so those never match as-is. This strips the noise.
enum QueryCleaner {
    private static let versionHints = [
        "remaster", "live", "mono", "stereo", "remix", "radio edit", "single version", "album version",
        "deluxe", "bonus", "acoustic", "version", "edit", "demo", "anniversary", "from ",
    ]

    /// "Song (feat. X) - Remastered 2011" -> "Song"
    static func title(_ raw: String) -> String {
        var s = stripBrackets(raw)
        if let r = s.range(of: " - ") {
            let tail = s[r.upperBound...].lowercased()
            let hasYear = tail.range(of: "\\b(19|20)\\d\\d\\b", options: .regularExpression) != nil
            if hasYear || versionHints.contains(where: { tail.contains($0) }) {
                s = String(s[..<r.lowerBound])
            }
        }
        s = cut(s, at: [" feat.", " feat ", " ft.", " ft ", " featuring "])
        let cleaned = collapse(s)
        return cleaned.isEmpty ? raw.trimmed : cleaned
    }

    /// "Mark Ronson, Bruno Mars" -> "Mark Ronson"
    static func artist(_ raw: String) -> String {
        var s = stripBrackets(raw)
        s = cut(s, at: [",", ";", " & ", " and ", " feat.", " feat ", " ft.", " ft ", " featuring ", " with ", " x ", " × ", " / "])
        let cleaned = collapse(s)
        return cleaned.isEmpty ? raw.trimmed : cleaned
    }

    /// Lowercase letters and digits only, for comparing names.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func stripBrackets(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if "([{".contains(ch) { depth += 1; continue }
            if ")]}".contains(ch) { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    private static func cut(_ s: String, at markers: [String]) -> String {
        var end = s.endIndex
        for m in markers {
            if let r = s.range(of: m, options: .caseInsensitive), r.lowerBound < end { end = r.lowerBound }
        }
        return String(s[..<end])
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// LRCLIB (https://lrclib.net): free and open, but LINE-level timestamps only,
/// so word times are estimated by LRC.parse.
struct LRCLibProvider: LyricsProvider {
    private struct Item: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?

        var hasSynced: Bool { (syncedLyrics ?? "").contains("[") }
    }

    func best(for track: Track) async throws -> LyricsCandidate? {
        let title = QueryCleaner.title(track.title)
        let artist = QueryCleaner.artist(track.artist)

        // 1. Exact lookup (needs both names). Duration must match within ~2 s, which picks the right version.
        if !title.isEmpty, !artist.isEmpty {
            var q = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
            if track.duration >= 1 { q.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }
            if let (data, code) = try? await request("get", q), code == 200,
               let item = try? JSONDecoder().decode(Item.self, from: data), item.hasSynced {
                return candidate(from: item)
            }
        }

        // 2. Search. Only auto-pick a result whose artist and length fit; otherwise let the user choose.
        let items = try await ranked(track: track, title: track.title, artist: track.artist, exact: false)
        guard let top = items.first else { return nil }
        let wantArtist = QueryCleaner.normalize(artist)
        let artistOK = wantArtist.isEmpty || QueryCleaner.normalize(top.artistName ?? "").contains(wantArtist)
        let durationOK = track.duration <= 0 || abs((top.duration ?? .infinity) - track.duration) <= 6
        return (artistOK && durationOK) ? candidate(from: top) : nil
    }

    func alternatives(for track: Track, exact: Bool) async throws -> [LyricsCandidate] {
        let items = try await ranked(track: track, title: track.title, artist: track.artist, exact: exact)
        return items.prefix(10).compactMap { candidate(from: $0) }
    }

    /// Runs up to four searches, from strict to loose, until there are enough synced results.
    private func ranked(track: Track, title rawTitle: String, artist rawArtist: String, exact: Bool) async throws -> [Item] {
        let title = exact ? rawTitle.trimmed : QueryCleaner.title(rawTitle)
        let artist = exact ? rawArtist.trimmed : QueryCleaner.artist(rawArtist)

        var attempts: [[URLQueryItem]] = []
        if !title.isEmpty, !artist.isEmpty {
            attempts.append([URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)])
            attempts.append([URLQueryItem(name: "q", value: "\(artist) \(title)")])
        }
        if !title.isEmpty { attempts.append([URLQueryItem(name: "q", value: title)]) }
        if title.isEmpty, !artist.isEmpty { attempts.append([URLQueryItem(name: "q", value: artist)]) }
        if !exact, !rawTitle.trimmed.isEmpty, !rawArtist.trimmed.isEmpty,
           rawTitle.trimmed != title || rawArtist.trimmed != artist {
            attempts.append([URLQueryItem(name: "track_name", value: rawTitle.trimmed),
                             URLQueryItem(name: "artist_name", value: rawArtist.trimmed)])
        }

        var items: [Item] = []
        var seen = Set<Int>()
        var firstError: Error?
        for q in attempts {
            do {
                let (data, code) = try await request("search", q)
                if code >= 400 { throw LyricsError.http(code) }
                for it in (try? JSONDecoder().decode([Item].self, from: data)) ?? [] where seen.insert(it.id).inserted {
                    items.append(it)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
            if items.filter({ $0.hasSynced }).count >= 3 { break }
        }
        if items.isEmpty, let e = firstError { throw e }

        let wantTitle = QueryCleaner.normalize(title)
        let wantArtist = QueryCleaner.normalize(artist)
        func score(_ it: Item) -> (artist: Int, title: Int, length: Double) {
            let a = QueryCleaner.normalize(it.artistName ?? "")
            let t = QueryCleaner.normalize(it.trackName ?? "")
            var artistScore = 0
            if !wantArtist.isEmpty, a.contains(wantArtist) { artistScore = 1 }
            var titleScore = 0
            if !wantTitle.isEmpty, !t.isEmpty {
                if t == wantTitle { titleScore = 2 } else if t.contains(wantTitle) || wantTitle.contains(t) { titleScore = 1 }
            }
            let length = track.duration > 0 ? abs((it.duration ?? 9999) - track.duration) : 0
            return (artistScore, titleScore, length)
        }
        return items.filter { $0.hasSynced }.sorted { a, b in
            let x = score(a), y = score(b)
            if x.artist != y.artist { return x.artist > y.artist }
            if x.title != y.title { return x.title > y.title }
            return x.length < y.length
        }
    }

    private func candidate(from item: Item) -> LyricsCandidate? {
        guard item.hasSynced, let lrc = item.syncedLyrics else { return nil }
        var parts = ["LRCLIB"]
        parts.append([item.artistName, item.trackName].compactMap { $0 }.joined(separator: " – "))
        if let album = item.albumName, !album.isEmpty { parts.append(album) }
        if let d = item.duration { parts.append(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)) }
        return LyricsCandidate(id: "lrclib:\(item.id)", label: parts.joined(separator: " · "),
                               lrc: lrc, duration: item.duration)
    }

    /// GET with one retry on 503 (the service asks clients to retry after a second).
    private func request(_ path: String, _ items: [URLQueryItem]) async throws -> (Data, Int) {
        var c = URLComponents(string: "https://lrclib.net/api/\(path)")!
        c.queryItems = items
        // URLComponents leaves "+" alone, which servers read as a space ("AC+DC").
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: c.url!, timeoutInterval: 10)
        req.setValue("NekoLyrics/0.5 (personal lyrics display)", forHTTPHeaderField: "User-Agent")

        for attempt in 0..<2 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 503, attempt == 0 {
                    try await Task.sleep(nanoseconds: 1_100_000_000)
                    continue
                }
                return (data, code)
            } catch let e as URLError {
                throw LyricsError.network(e.localizedDescription)
            }
        }
        throw LyricsError.http(503)
    }
}
