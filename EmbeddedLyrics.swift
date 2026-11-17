import Foundation

struct EmbeddedResult {
    var candidates: [LyricsCandidate] = []
    /// Lyrics were found in the file, but without timestamps, so they can't be synced.
    var foundUnsynced = false
}

private typealias Found = (id: String, label: String, text: String)

/// Reads lyrics stored inside an audio file (and a sidecar .lrc next to it).
///  - MP3: ID3v2 USLT (text, often LRC) and SYLT (synced) frames
///  - M4A/MP4: the ©lyr atom
///  - FLAC: LYRICS / UNSYNCEDLYRICS / SYNCEDLYRICS Vorbis comments
///  - song.lrc next to song.ext
enum EmbeddedLyrics {
    static func read(path: String) -> EmbeddedResult {
        var found: [Found] = []

        if let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            if let head = try? fh.read(upToCount: 12) {
                let h = [UInt8](head)
                if h.starts(with: Array("ID3".utf8)) {
                    found += ID3.lyrics(fh)
                } else if h.starts(with: Array("fLaC".utf8)) {
                    found += FLAC.lyrics(fh)
                } else if h.count >= 8, Array(h[4..<8]) == Array("ftyp".utf8) {
                    found += MP4.lyrics(fh)
                }
            }
        }

        let sidecar = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("lrc")
        if let data = try? Data(contentsOf: sidecar) {
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            found.append((id: "sidecar", label: "Sidecar .lrc file", text: text))
        }

        var result = EmbeddedResult()
        var seen = Set<String>()
        for f in found {
            let isSidecar = f.id == "sidecar"
            if LRC.isSynced(f.text) {
                guard seen.insert(f.text).inserted else { continue }
                result.candidates.append(LyricsCandidate(
                    id: isSidecar ? "sidecar" : "embedded:\(f.id)",
                    label: isSidecar ? f.label : "Embedded · \(f.label)",
                    lrc: f.text, duration: nil))
            } else if !f.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.foundUnsynced = true
            }
        }
        return result
    }
}

// MARK: - Byte helpers (bounds-safe)

private func be32(_ b: [UInt8], _ i: Int) -> Int {
    guard i >= 0, i + 4 <= b.count else { return 0 }
    return (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
}

private func syncsafe(_ b: [UInt8], _ i: Int) -> Int {
    guard i >= 0, i + 4 <= b.count else { return 0 }
    return (Int(b[i] & 0x7F) << 21) | (Int(b[i + 1] & 0x7F) << 14) | (Int(b[i + 2] & 0x7F) << 7) | Int(b[i + 3] & 0x7F)
}

// MARK: - ID3v2 (MP3)

private enum ID3 {
    static func lyrics(_ fh: FileHandle) -> [Found] {
        do {
            try fh.seek(toOffset: 0)
            guard let hd = try fh.read(upToCount: 10), hd.count == 10 else { return [] }
            let h = [UInt8](hd)
            let major = Int(h[3])
            let flags = h[5]
            let size = syncsafe(h, 6)
            guard (2...4).contains(major), size > 0, size < 64_000_000 else { return [] }
            if major == 2 && flags & 0x40 != 0 { return [] }   // v2.2 compression: unsupported

            guard let body = try fh.read(upToCount: size) else { return [] }
            var b = [UInt8](body)
            if flags & 0x80 != 0 { b = unsync(b) }

            var pos = 0
            if major >= 3 && flags & 0x40 != 0 {               // extended header
                pos = major == 3 ? 4 + be32(b, 0) : syncsafe(b, 0)
            }

            let idLen = major == 2 ? 3 : 4
            let hdrLen = major == 2 ? 6 : 10
            var out: [Found] = []

            while pos >= 0, pos + hdrLen <= b.count {
                if b[pos] == 0 { break }                        // padding
                let id = String(decoding: b[pos..<pos + idLen], as: UTF8.self)
                let fsize: Int
                switch major {
                case 2: fsize = (Int(b[pos + 3]) << 16) | (Int(b[pos + 4]) << 8) | Int(b[pos + 5])
                case 3: fsize = be32(b, pos + 4)
                default: fsize = syncsafe(b, pos + 4)
                }
                let fmtFlags: UInt8 = major >= 3 ? b[pos + 9] : 0
                let start = pos + hdrLen
                let end = start + fsize
                guard fsize > 0, end <= b.count else { break }
                pos = end

                guard ["USLT", "ULT", "SYLT", "SLT"].contains(id) else { continue }
                var frame = Array(b[start..<end])

                if major == 3 {
                    if fmtFlags & 0xC0 != 0 { continue }        // compressed or encrypted
                    if fmtFlags & 0x20 != 0 { guard frame.count > 1 else { continue }; frame.removeFirst(1) }
                } else if major == 4 {
                    if fmtFlags & 0x0C != 0 { continue }        // compressed or encrypted
                    if fmtFlags & 0x40 != 0 { guard frame.count > 1 else { continue }; frame.removeFirst(1) }
                    if fmtFlags & 0x01 != 0 { guard frame.count > 4 else { continue }; frame.removeFirst(4) }
                    if fmtFlags & 0x02 != 0 { frame = unsync(frame) }
                }

                if id == "USLT" || id == "ULT" {
                    if let t = parseUSLT(frame) {
                        out.append((id: "uslt\(out.count)", label: "ID3 USLT", text: t))
                    }
                } else if let t = parseSYLT(frame) {
                    out.append((id: "sylt\(out.count)", label: "ID3 SYLT (synced)", text: t))
                }
            }
            return out
        } catch {
            return []
        }
    }

    // USLT: encoding(1) language(3) descriptor(terminated) text
    static func parseUSLT(_ f: [UInt8]) -> String? {
        guard f.count >= 5 else { return nil }
        let enc = f[0]
        guard let textStart = terminatorEnd(f, from: 4, enc: enc) else { return nil }
        return decode(Array(f[textStart...]), enc: enc)
    }

    // SYLT: encoding(1) language(3) timestampFormat(1) contentType(1) descriptor(terminated)
    //       then repeated: text(terminated) + timestamp(4 bytes, big endian)
    static func parseSYLT(_ f: [UInt8]) -> String? {
        guard f.count >= 7 else { return nil }
        let enc = f[0]
        guard f[4] == 2, f[5] <= 1 else { return nil }          // only milliseconds timestamps, lyrics content
        guard var i = terminatorEnd(f, from: 6, enc: enc) else { return nil }

        let termLen = (enc == 1 || enc == 2) ? 2 : 1
        var entries: [(ms: Int, text: String)] = []
        while i < f.count {
            guard let end = terminatorEnd(f, from: i, enc: enc), end + 4 <= f.count else { break }
            let text = decode(Array(f[i..<(end - termLen)]), enc: enc)
            entries.append((ms: be32(f, end), text: text))
            i = end + 4
        }
        return entries.isEmpty ? nil : lrc(fromSYLT: entries)
    }

    /// Turns SYLT entries into LRC text. Taggers store either one entry per line,
    /// or one per word/syllable with newlines marking line breaks.
    static func lrc(fromSYLT entries: [(ms: Int, text: String)]) -> String {
        let startsWithNL = entries.dropFirst().contains { $0.text.hasPrefix("\n") || $0.text.hasPrefix("\r") }
        let endingNL = entries.filter { $0.text.hasSuffix("\n") }.count
        let syllableMode = startsWithNL || (endingNL > 0 && endingNL * 10 < entries.count * 7)

        if !syllableMode {
            return entries.map { e in
                "[\(LRC.stamp(e.ms))]" + e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: "\n")
        }

        var lines: [[(ms: Int, text: String)]] = []
        var words: [(ms: Int, text: String)] = []
        var word = ""
        var wordMs = 0
        func flushWord() {
            if !word.isEmpty { words.append((ms: wordMs, text: word)); word = "" }
        }
        func flushLine() {
            flushWord()
            if !words.isEmpty { lines.append(words); words = [] }
        }

        for e in entries {
            if e.text.hasPrefix("\n") || e.text.hasPrefix("\r") { flushLine() }
            let t = e.text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if t.hasPrefix(" ") || t.hasPrefix("\t") { flushWord() }
            let core = t.trimmingCharacters(in: .whitespaces)
            if !core.isEmpty {
                if word.isEmpty { wordMs = e.ms }
                word += core
            }
            if t.hasSuffix(" ") || t.hasSuffix("\t") { flushWord() }
            if e.text.hasSuffix("\n") { flushLine() }
        }
        flushLine()

        return lines.map { l in
            "[\(LRC.stamp(l[0].ms))]" + l.map { "<\(LRC.stamp($0.ms))>\($0.text) " }.joined()
        }.joined(separator: "\n")
    }

    /// Index just past the string terminator (one zero byte, or two for UTF-16).
    static func terminatorEnd(_ b: [UInt8], from: Int, enc: UInt8) -> Int? {
        var i = from
        if enc == 1 || enc == 2 {
            while i + 1 < b.count {
                if b[i] == 0 && b[i + 1] == 0 { return i + 2 }
                i += 2
            }
        } else {
            while i < b.count {
                if b[i] == 0 { return i + 1 }
                i += 1
            }
        }
        return nil
    }

    static func decode(_ bytes: [UInt8], enc: UInt8) -> String {
        let d = Data(bytes)
        var s: String?
        switch enc {
        case 0:
            // Spec says Latin-1, but many taggers write UTF-8 here.
            s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
        case 1:
            if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
                s = String(data: d, encoding: .utf16)
            } else {
                s = String(data: d, encoding: .utf16LittleEndian)
            }
        case 2:
            s = String(data: d, encoding: .utf16BigEndian)
        default:
            s = String(data: d, encoding: .utf8)
        }
        return (s ?? "").replacingOccurrences(of: "\0", with: "")
    }

    /// Undo "unsynchronisation": 0xFF 0x00 -> 0xFF.
    static func unsync(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0 { i += 1 }
            i += 1
        }
        return out
    }
}

// MARK: - FLAC

private enum FLAC {
    static func lyrics(_ fh: FileHandle) -> [Found] {
        do {
            var offset: UInt64 = 4
            while true {
                try fh.seek(toOffset: offset)
                guard let hd = try fh.read(upToCount: 4), hd.count == 4 else { break }
                let h = [UInt8](hd)
                let isLast = h[0] & 0x80 != 0
                let type = h[0] & 0x7F
                let len = (Int(h[1]) << 16) | (Int(h[2]) << 8) | Int(h[3])
                if type == 4 {                                  // VORBIS_COMMENT
                    guard len < 16_000_000, let body = try fh.read(upToCount: len) else { break }
                    return parseVorbis([UInt8](body))
                }
                if isLast { break }
                offset += 4 + UInt64(len)
            }
        } catch {}
        return []
    }

    static func parseVorbis(_ b: [UInt8]) -> [Found] {
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= b.count else { return nil }
            let v = Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
            i += 4
            return v
        }
        guard let vendor = u32(), vendor >= 0, i + vendor <= b.count else { return [] }
        i += vendor
        guard let count = u32() else { return [] }

        let wanted: Set<String> = ["LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS", "LRC", "LYRICS_SYNCED"]
        var out: [Found] = []
        for _ in 0..<min(count, 10_000) {
            guard let len = u32(), len >= 0, i + len <= b.count else { break }
            let s = String(decoding: b[i..<i + len], as: UTF8.self)
            i += len
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased()
            if wanted.contains(key) {
                out.append((id: "\(key.lowercased())\(out.count)", label: "FLAC \(key)",
                            text: String(s[s.index(after: eq)...])))
            }
        }
        return out
    }
}

// MARK: - MP4 / M4A

private enum MP4 {
    static func lyrics(_ fh: FileHandle) -> [Found] {
        do {
            let size = try fh.seekToEnd()
            var offset: UInt64 = 0
            while offset + 8 <= size {
                try fh.seek(toOffset: offset)
                guard let hd = try fh.read(upToCount: 16), hd.count >= 8 else { break }
                let h = [UInt8](hd)
                var atomSize = UInt64(be32(h, 0))
                var headerLen: UInt64 = 8
                if atomSize == 1 {
                    guard h.count >= 16 else { break }
                    atomSize = (UInt64(be32(h, 8)) << 32) | UInt64(be32(h, 12))
                    headerLen = 16
                } else if atomSize == 0 {
                    atomSize = size - offset
                }
                guard atomSize >= headerLen else { break }

                if Array(h[4..<8]) == Array("moov".utf8) {
                    let bodyLen = atomSize - headerLen
                    guard bodyLen < 128_000_000 else { break }
                    try fh.seek(toOffset: offset + headerLen)
                    guard let body = try fh.read(upToCount: Int(bodyLen)) else { break }
                    return fromMoov([UInt8](body))
                }
                offset += atomSize
            }
        } catch {}
        return []
    }

    // moov / udta / meta / ilst / ©lyr / data
    static func fromMoov(_ b: [UInt8]) -> [Found] {
        guard let udta = child(b, "udta", in: 0..<b.count),
              let meta = child(b, "meta", in: udta),
              meta.lowerBound + 4 <= meta.upperBound,
              let ilst = child(b, "ilst", in: (meta.lowerBound + 4)..<meta.upperBound),   // meta has 4 version/flag bytes
              let lyr = child(b, [0xA9, 0x6C, 0x79, 0x72], in: ilst),                      // "©lyr"
              let data = child(b, "data", in: lyr),
              data.lowerBound + 8 <= data.upperBound                                       // version/flags + locale
        else { return [] }
        let text = String(decoding: b[(data.lowerBound + 8)..<data.upperBound], as: UTF8.self)
        return [(id: "lyr", label: "M4A ©lyr", text: text)]
    }

    static func child(_ b: [UInt8], _ type: String, in range: Range<Int>) -> Range<Int>? {
        child(b, Array(type.utf8), in: range)
    }

    /// Body range of the first child atom of the given type inside `range`.
    static func child(_ b: [UInt8], _ type: [UInt8], in range: Range<Int>) -> Range<Int>? {
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            var size = be32(b, pos)
            var headerLen = 8
            if size == 1 {
                guard pos + 16 <= range.upperBound else { return nil }
                size = (be32(b, pos + 8) << 32) | be32(b, pos + 12)
                headerLen = 16
            } else if size == 0 {
                size = range.upperBound - pos
            }
            guard size >= headerLen, pos + headerLen <= range.upperBound else { return nil }
            let end = min(pos + size, range.upperBound)
            if Array(b[(pos + 4)..<(pos + 8)]) == type { return (pos + headerLen)..<end }
            pos += size
        }
        return nil
    }
}

// MARK: - Command-line inspector

/// `NekoLyrics.app/Contents/MacOS/NekoLyrics --inspect "/path/to/song.mp3"`
/// prints what the reader finds in a file, to check it against your own library.
enum Inspect {
    static func run(path: String) {
        let r = EmbeddedLyrics.read(path: path)
        print("File: \(path)")
        if r.candidates.isEmpty {
            print(r.foundUnsynced ? "Found lyrics, but they are NOT time-synced." : "No embedded or sidecar lyrics found.")
        }
        let f = { (x: Double) in String(format: "%.2f", x) }
        for c in r.candidates {
            let lines = LRC.parse(c.lrc, trackEnd: 0)
            print("• \(c.label): \(lines.count) lines")
            for l in lines.prefix(3) {
                print("   [\(f(l.start))] " + l.words.map { "\($0.text)@\(f($0.start))" }.joined(separator: " "))
            }
        }
    }
}
