import Foundation

/// Parser for LRC lyrics. Supports:
///  - "[mm:ss.xx] text" lines, several timestamps per line, [offset:ms]
///  - "enhanced" LRC with per-word tags: "[00:10.00]<00:10.00>Hello <00:10.40>world"
///    (these give REAL word timings; plain lines get estimated ones)
enum LRC {
    private static let junk = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))

    static func parse(_ text: String, trackEnd: TimeInterval) -> [Line] {
        struct Raw { var start: TimeInterval; var body: String }
        var raws: [Raw] = []
        var offset: TimeInterval = 0

        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: junk))
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if let t = timestamp(inner) {
                    times.append(t)
                } else if inner.lowercased().hasPrefix("offset:"),
                          let ms = Double(inner.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let body = rest.trimmingCharacters(in: .whitespaces)
            for t in times { raws.append(Raw(start: t, body: body)) }
        }

        // Stable sort by time. Empty-body entries stay: they mark instrumental gaps.
        let sorted = raws.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map { $0.element }

        let rate = singingRate(sorted.enumerated().map { i, item in
            let next = i + 1 < sorted.count ? sorted[i + 1].start : item.start + 6
            return (item.body, next - item.start)
        })

        var lines: [Line] = []
        for (i, item) in sorted.enumerated() where !item.body.isEmpty {
            // Spec: a positive [offset:] makes lyrics appear sooner.
            let start = item.start - offset
            let nextStart = i + 1 < sorted.count ? sorted[i + 1].start - offset : max(trackEnd, start + 4)
            let words = buildWords(body: item.body, lineStart: start, nextStart: nextStart, offset: offset, rate: rate)
            guard !words.isEmpty else { continue }
            lines.append(Line(words: words, start: start, end: nextStart))
        }
        return lines
    }

    /// True when the text has real timestamps (at least two timed lines).
    static func isSynced(_ text: String) -> Bool {
        parse(text, trackEnd: 0).count >= 2
    }

    /// First line of text, for showing a preview in the picker.
    static func preview(_ text: String) -> String {
        guard let first = parse(text, trackEnd: 0).first else { return "" }
        return first.words.map { $0.text }.joined(separator: " ")
    }

    /// "mm:ss.xx"
    static func stamp(_ ms: Int) -> String {
        let total = max(ms, 0)
        return String(format: "%02ld:%02ld.%02ld", total / 60000, (total / 1000) % 60, (total % 1000) / 10)
    }

    // MARK: - Internals

    private static func buildWords(body: String, lineStart: TimeInterval, nextStart: TimeInterval,
                                   offset: TimeInterval, rate: Double) -> [Word] {
        let segs = splitWordTags(body)

        if segs.contains(where: { $0.time != nil }) {
            var out: [Word] = []
            for (i, seg) in segs.enumerated() {
                let pieces = seg.text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard !pieces.isEmpty else { continue }
                let s = seg.time.map { $0 - offset } ?? lineStart
                var e = min(nextStart, s + 1.5)
                if let later = segs[(i + 1)...].first(where: { $0.time != nil })?.time {
                    e = later - offset
                }
                out += spread(pieces, from: s, to: max(e, s + 0.05))
            }
            return out
        }

        // Plain line: estimate. Syllable-weighted, at this song's own singing speed, with a short
        // lead-in and pauses after commas / full stops. A line is rarely sung across its whole gap.
        let pieces = body.split(separator: " ").map(String.init)
        guard !pieces.isEmpty else { return [] }
        return estimate(pieces, start: lineStart, span: max(nextStart - lineStart, 0.3), rate: rate)
    }

    // MARK: Word timing estimate

    /// Rough syllable count (vowel groups, silent final e, one per CJK character).
    static func syllables(_ word: String) -> Int {
        let lw = word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        if lw.isEmpty { return 1 }
        let cjk = lw.unicodeScalars.filter { $0.value >= 0x2E80 }.count
        if cjk > 0 { return cjk }
        let vowels = Set("aeiouyáéíóúàèìòùâêîôûäëïöüåæœ")
        var n = 0
        var prev = false
        for c in lw {
            let v = vowels.contains(c)
            if v && !prev { n += 1 }
            prev = v
        }
        if n > 1, lw.hasSuffix("e"), !lw.hasSuffix("le"), !lw.hasSuffix("ee") { n -= 1 }
        if lw.hasSuffix("ed") && n > 1 && !(lw.hasSuffix("ted") || lw.hasSuffix("ded")) { n -= 1 }
        return max(n, 1)
    }

    /// Silence after a word, in syllable units.
    private static func pause(after word: String) -> Double {
        guard let last = word.last else { return 0 }
        if ".?!…—–".contains(last) { return 0.9 }
        if ",;:".contains(last) { return 0.5 }
        return 0
    }

    /// Syllables per second for the whole song: the median over lines that are sung back to back.
    private static func singingRate(_ items: [(body: String, span: TimeInterval)]) -> Double {
        var samples: [Double] = []
        for it in items where !it.body.isEmpty && !it.body.contains("<") && it.span > 0.6 && it.span < 7 {
            let syl = it.body.split(separator: " ").reduce(0) { $0 + syllables(String($1)) }
            samples.append(Double(syl) / (it.span * 0.9))
        }
        guard samples.count >= 4 else { return 4.2 }
        samples.sort()
        return min(max(samples[samples.count / 2], 2.5), 7.0)
    }

    private static func estimate(_ pieces: [String], start: TimeInterval, span: TimeInterval, rate: Double) -> [Word] {
        let syl = pieces.map { Double(syllables($0)) }
        var gap = pieces.map { pause(after: $0) }
        gap[gap.count - 1] = 0
        let units = zip(syl, gap).reduce(0.0) { $0 + $1.0 + $1.1 }

        let lead = span > 1.2 ? 0.1 : 0.0           // singers start a touch after the stamp
        let avail = max(span * 0.94 - lead, 0.2)
        let sing = min(avail, units / rate)         // short line: sung at natural speed, then silence
        let per = sing / units                      // seconds per syllable unit

        var t = start + lead
        var out: [Word] = []
        for i in pieces.indices {
            let d = syl[i] * per
            var end = t + d
            if i == pieces.count - 1 {              // last word is held a little
                end = min(t + d * 1.35, start + lead + avail)
            }
            out.append(Word(text: pieces[i], start: t, end: max(end, t + 0.08)))
            t += (syl[i] + gap[i]) * per
        }
        return out
    }

    private static func spread(_ pieces: [String], from start: TimeInterval, to end: TimeInterval) -> [Word] {
        let weights = pieces.map { Double($0.count) + 1 }
        let sum = weights.reduce(0, +)
        var t = start
        var out: [Word] = []
        for (p, w) in zip(pieces, weights) {
            let d = (end - start) * w / sum
            out.append(Word(text: p, start: t, end: t + d))
            t += d
        }
        return out
    }

    /// Splits "<00:10.00>Hello <00:10.40>world" into [(10.0, "Hello "), (10.4, "world")].
    private static func splitWordTags(_ body: String) -> [(time: TimeInterval?, text: String)] {
        var segs: [(time: TimeInterval?, text: String)] = []
        var cur = ""
        var curTime: TimeInterval? = nil
        var i = body.startIndex
        while i < body.endIndex {
            if body[i] == "<",
               let close = body[i...].firstIndex(of: ">"),
               let t = timestamp(body[body.index(after: i)..<close]) {
                if !cur.isEmpty || curTime != nil { segs.append((time: curTime, text: cur)) }
                cur = ""
                curTime = t
                i = body.index(after: close)
            } else {
                cur.append(body[i])
                i = body.index(after: i)
            }
        }
        if !cur.isEmpty || curTime != nil { segs.append((time: curTime, text: cur)) }
        return segs
    }

    /// "mm:ss.xx", "mm:ss,xx" or the older "mm:ss:xx". Returns nil for metadata tags like "ar:Artist".
    private static func timestamp(_ s: Substring) -> TimeInterval? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3,
              let minutes = Double(parts[0]), minutes.isFinite, minutes >= 0 else { return nil }
        if parts.count == 2 {
            guard let secs = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  secs.isFinite, secs >= 0 else { return nil }
            return minutes * 60 + secs
        }
        guard let secs = Double(parts[1]), secs.isFinite, secs >= 0,
              let frac = Double("0." + parts[2]), frac.isFinite else { return nil }
        return minutes * 60 + secs + frac
    }
}
