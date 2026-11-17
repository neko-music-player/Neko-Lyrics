import Foundation

/// Word-timed lyrics from Apple Music's TTML sheets, through the public catalogue at lyrics-api.binimum.org
/// (the same source the open-source Sonora player reads; no account or key). Falls back to LRCLIB.
/// Sheets are converted to "enhanced LRC" so the normal parser gets REAL word times.
struct AppleWordProvider: LyricsProvider {
    private struct Found: Decodable { let results: [Match]? }
    private struct Match: Decodable {
        let track_name: String?
        let artist_name: String?
        let album_name: String?
        let duration: Double?
        let timing_type: String?
        let lyricsUrl: String?
        var worded: Bool { timing_type == "word" || timing_type == "syllable" }
    }

    func best(for track: Track) async throws -> LyricsCandidate? {
        let matches = try await find(track, title: QueryCleaner.title(track.title), artist: QueryCleaner.artist(track.artist))
        for m in matches.prefix(2) {
            if let c = await candidate(from: m) { return c }
        }
        return nil
    }

    func alternatives(for track: Track, exact: Bool) async throws -> [LyricsCandidate] {
        let title = exact ? track.title : QueryCleaner.title(track.title)
        let artist = exact ? track.artist : QueryCleaner.artist(track.artist)
        let matches = try await find(track, title: title, artist: artist)
        var out: [LyricsCandidate] = []
        for m in matches.prefix(3) {
            if let c = await candidate(from: m) { out.append(c) }
        }
        return out
    }

    private func find(_ track: Track, title: String, artist: String) async throws -> [Match] {
        guard !title.isEmpty else { return [] }
        var items = [URLQueryItem(name: "track", value: title), URLQueryItem(name: "artist", value: artist)]
        if track.duration >= 1 { items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }
        var results = try await query(items + (track.album.isEmpty ? [] : [URLQueryItem(name: "album", value: track.album)]))
        if results.isEmpty, !track.album.isEmpty { results = try await query(items) }   // album may be named differently
        return results.filter { $0.lyricsUrl != nil }.sorted { a, b in a.worded && !b.worded }
    }

    private func query(_ items: [URLQueryItem]) async throws -> [Match] {
        var c = URLComponents(string: "https://lyrics-api.binimum.org/")!
        c.queryItems = items
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: c.url!, timeoutInterval: 10)
        req.setValue("NekoLyrics/1.3 (personal lyrics display)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return [] }
            guard code == 200 else { throw LyricsError.http(code) }
            return (try? JSONDecoder().decode(Found.self, from: data))?.results ?? []
        } catch let e as URLError {
            throw LyricsError.network(e.localizedDescription)
        }
    }

    private func candidate(from m: Match) async -> LyricsCandidate? {
        guard let urlString = m.lyricsUrl, urlString.hasPrefix("https://"), let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("NekoLyrics/1.3 (personal lyrics display)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let lrc = TTMLConverter.lrc(from: data), lrc.contains("[") else { return nil }
        var parts = ["Apple Music" + (m.worded ? " (word-timed)" : "")]
        parts.append([m.artist_name, m.track_name].compactMap { $0 }.joined(separator: " – "))
        if let a = m.album_name, !a.isEmpty { parts.append(a) }
        let id = "apple:" + String(StableHash.value(urlString, salt: 7), radix: 16)
        return LyricsCandidate(id: id, label: parts.joined(separator: " · "), lrc: lrc, duration: m.duration)
    }
}

/// Tries Apple's word-timed sheets first, then LRCLIB's line-timed ones.
struct WordFirstProvider: LyricsProvider {
    let word = AppleWordProvider()
    let lines = LRCLibProvider()

    func best(for track: Track) async throws -> LyricsCandidate? {
        if let c = try? await word.best(for: track) { return c }
        return try await lines.best(for: track)
    }

    func alternatives(for track: Track, exact: Bool) async throws -> [LyricsCandidate] {
        let a: [LyricsCandidate] = (try? await word.alternatives(for: track, exact: exact)) ?? []
        let b: [LyricsCandidate] = (try? await lines.alternatives(for: track, exact: exact)) ?? []
        return a + b
    }
}

/// TTML -> enhanced LRC ("[mm:ss.xx]<mm:ss.xx>word <mm:ss.xx>word <mm:ss.xx>").
enum TTMLConverter {
    static func lrc(from data: Data) -> String? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let out = reader.lines.compactMap { line -> String? in
            if line.words.isEmpty {
                let text = line.plain.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : "[\(stamp(line.start))]\(text)"
            }
            var s = "[\(stamp(line.words[0].start))]"
            for w in line.words { s += "<\(stamp(w.start))>\(w.text) " }
            s += "<\(stamp(line.words[line.words.count - 1].end))>"
            return s
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    private static func stamp(_ t: Double) -> String { LRC.stamp(Int((t * 1000).rounded())) }

    private struct Syl { var start: Double; var end: Double; var text: String }
    private struct Line { var start: Double = 0; var words: [(start: Double, end: Double, text: String)] = []; var plain = "" }

    private final class Reader: NSObject, XMLParserDelegate {
        var lines: [Line] = []
        private var line: Line?
        private var inP = false
        private var skip = 0                       // >0 inside background vocals / translations
        private var spans: [(begin: Double?, end: Double?, text: String, skipped: Bool)] = []
        private var sylls: [(syl: Syl, spaceAfter: Bool)] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            let tag = name.split(separator: ":").last.map(String.init) ?? name
            if tag == "p" {
                inP = true
                line = Line(start: TTMLConverter.time(a["begin"]) ?? 0)
                sylls = []
                spans = []
                skip = 0
            } else if inP, tag == "span" {
                let role = a["ttm:role"] ?? ""
                let skipped = role == "x-bg" || role == "x-translation" || role == "x-roman"
                if skipped { skip += 1 }
                spans.append((TTMLConverter.time(a["begin"]), TTMLConverter.time(a["end"]), "", skipped))
            } else if inP, tag == "br" {
                markSpace()
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) {
            guard inP else { return }
            if skip > 0 { return }
            line?.plain += s
            if var last = spans.last, last.begin != nil {
                last.text += s
                spans[spans.count - 1] = last
            } else if s.contains(where: { $0 == " " || $0 == "\n" }) {
                markSpace()
            }
        }

        private func markSpace() {
            if !sylls.isEmpty { sylls[sylls.count - 1].spaceAfter = true }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let tag = name.split(separator: ":").last.map(String.init) ?? name
            if inP, tag == "span", let span = spans.popLast() {
                if span.skipped { skip -= 1 }
                else if let b = span.begin, !span.text.isEmpty {
                    let trimmed = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let endsSpace = span.text.last?.isWhitespace ?? false
                        sylls.append((Syl(start: b, end: span.end ?? b, text: trimmed), endsSpace))
                    }
                }
            } else if tag == "p" {
                inP = false
                guard var l = line else { return }
                // Syllables with no space between them make one word.
                var words: [(start: Double, end: Double, text: String)] = []
                var glue = false
                for item in sylls {
                    if glue, var last = words.popLast() {
                        last.text += item.syl.text
                        last.end = max(item.syl.end, last.end)
                        words.append(last)
                    } else {
                        words.append((item.syl.start, item.syl.end, item.syl.text))
                    }
                    glue = !item.spaceAfter
                }
                l.words = words
                lines.append(l)
                line = nil
            }
        }
    }

    /// "1:23.456", "23.456", "00:01:23.456", "12.3s"
    static func time(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        let parts = s.split(separator: ":").map(String.init)
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }
}
