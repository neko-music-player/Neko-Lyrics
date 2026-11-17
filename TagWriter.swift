import Foundation

enum TagError: LocalizedError {
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Not supported: \(s)"
        case .failed(let s): return s
        }
    }
}

/// Writes lyrics into audio files. Safety rules for every format:
///  1. build the new file in memory and write it to a temp file next to the original
///  2. re-read the temp file with the same reader the app uses and check the lyrics match
///  3. keep a one-time backup of the ORIGINAL in ~/Library/Application Support/NekoLyrics/Backups
///  4. only then swap the temp file in
/// The audio data itself is copied byte-for-byte, never re-encoded.
enum TagWriter {
    static func embed(lrc: String, intoFileAt path: String) throws -> URL {
        guard LRC.isSynced(lrc) else { throw TagError.failed("Only time-synced lyrics can be embedded.") }
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default

        let attrs = try fm.attributesOfItem(atPath: path)
        if let size = attrs[.size] as? NSNumber, size.intValue > 600_000_000 {
            throw TagError.unsupported("files larger than 600 MB")
        }
        let f = [UInt8](try Data(contentsOf: url))
        let ext = url.pathExtension.lowercased()

        let out: [UInt8]
        if f.starts(with: Array("fLaC".utf8)) {
            out = try FLACWriter.rewrite(f, lrc: lrc)
        } else if f.count >= 8, Array(f[4..<8]) == Array("ftyp".utf8) {
            out = try MP4Writer.rewrite(f, lrc: lrc)
        } else if f.starts(with: Array("ID3".utf8)) || ext == "mp3" || (f.count > 2 && f[0] == 0xFF && (f[1] & 0xE0) == 0xE0) {
            out = try MP3Writer.rewrite(f, lrc: lrc)
        } else {
            throw TagError.unsupported("this file type (.\(ext))")
        }

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).nekolyrics-tmp")
        try? fm.removeItem(at: tmp)
        try Data(out).write(to: tmp)

        let want = lrc.trimmingCharacters(in: .whitespacesAndNewlines)
        let check = EmbeddedLyrics.read(path: tmp.path)
        guard check.candidates.contains(where: { $0.lrc.trimmingCharacters(in: .whitespacesAndNewlines) == want }) else {
            try? fm.removeItem(at: tmp)
            throw TagError.failed("Verification failed, so your file was NOT changed.")
        }

        let backup = backupURL(for: url)
        do {
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw TagError.failed("Couldn't replace the file: \(error.localizedDescription)")
        }
        return backup
    }

    static func saveSidecar(lrc: String, to url: URL) throws {
        try lrc.write(to: url, atomically: true, encoding: .utf8)
    }

    static func backupURL(for url: URL) -> URL {
        var h: UInt32 = 2_166_136_261                         // FNV-1a: stable across launches
        for b in url.path.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return AppSupport.directory.appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(String(format: "%08x-", h) + url.lastPathComponent)
    }
}

// MARK: - Byte helpers

private func rd32(_ b: [UInt8], _ i: Int) -> Int {
    guard i >= 0, i + 4 <= b.count else { return 0 }
    return (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
}

private func rdSync(_ b: [UInt8], _ i: Int) -> Int {
    guard i >= 0, i + 4 <= b.count else { return 0 }
    return (Int(b[i] & 0x7F) << 21) | (Int(b[i + 1] & 0x7F) << 14) | (Int(b[i + 2] & 0x7F) << 7) | Int(b[i + 3] & 0x7F)
}

private func be32Bytes(_ v: Int) -> [UInt8] {
    [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

private func syncBytes(_ v: Int) -> [UInt8] {
    [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
}

private func le32Bytes(_ v: Int) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

// MARK: - MP3 (ID3v2.3 / v2.4)

private enum MP3Writer {
    /// Replaces every USLT frame with one USLT frame holding the LRC text. All other frames
    /// (title, cover art, SYLT ...) are copied unchanged.
    static func rewrite(_ f: [UInt8], lrc: String) throws -> [UInt8] {
        var major = 3
        var minor = 0
        var kept: [UInt8] = []
        var audioStart = 0

        if f.starts(with: Array("ID3".utf8)) {
            guard f.count >= 10 else { throw TagError.failed("Damaged ID3 tag.") }
            major = Int(f[3])
            minor = Int(f[4])
            let flags = f[5]
            guard major == 3 || major == 4 else { throw TagError.unsupported("ID3v2.\(major) tags") }
            guard flags & 0x80 == 0 else { throw TagError.unsupported("ID3 tags using unsynchronisation") }
            guard flags & 0x40 == 0 else { throw TagError.unsupported("ID3 tags with an extended header") }

            let tagEnd = 10 + rdSync(f, 6)
            guard tagEnd <= f.count else { throw TagError.failed("Damaged ID3 tag.") }
            audioStart = tagEnd + ((major == 4 && flags & 0x10 != 0) ? 10 : 0)   // skip a v2.4 footer
            guard audioStart <= f.count else { throw TagError.failed("Damaged ID3 tag.") }

            var pos = 10
            while pos + 10 <= tagEnd {
                if f[pos] == 0 { break }                                          // padding starts here
                let idBytes = f[pos..<pos + 4]
                guard idBytes.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) }) else {
                    throw TagError.failed("Couldn't understand the existing ID3 tag.")
                }
                let size = major == 3 ? rd32(f, pos + 4) : rdSync(f, pos + 4)
                let end = pos + 10 + size
                guard size >= 0, end <= tagEnd else { throw TagError.failed("Couldn't understand the existing ID3 tag.") }
                if String(decoding: idBytes, as: UTF8.self) != "USLT" { kept += f[pos..<end] }
                pos = end
            }
        }

        // New USLT frame: UTF-16 (with BOM), language "eng", empty description, then the text.
        var body: [UInt8] = [1]
        body += Array("eng".utf8)
        body += [0xFF, 0xFE, 0x00, 0x00]          // empty description (BOM + terminator)
        body += [0xFF, 0xFE]                        // BOM for the text
        for u in lrc.utf16 {
            body.append(UInt8(u & 0xFF))
            body.append(UInt8(u >> 8))
        }
        var frame: [UInt8] = Array("USLT".utf8)
        frame += major == 3 ? be32Bytes(body.count) : syncBytes(body.count)
        frame += [0, 0]                             // frame flags
        frame += body

        var frames = kept
        frames += frame
        frames += [UInt8](repeating: 0, count: 512)   // padding, so later tag edits don't rewrite the file

        var out: [UInt8] = Array("ID3".utf8)
        out += [UInt8(major), UInt8(minor), 0]
        out += syncBytes(frames.count)
        out += frames
        out += f[audioStart...]
        return out
    }
}

// MARK: - FLAC

private enum FLACWriter {
    static let lyricKeys: Set<String> = ["LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS", "LRC", "LYRICS_SYNCED"]

    /// Drops existing lyric fields and writes LYRICS=<lrc>. Other tags and the audio are untouched.
    static func rewrite(_ f: [UInt8], lrc: String) throws -> [UInt8] {
        var blocks: [(type: UInt8, body: [UInt8])] = []
        var pos = 4
        var audioStart = 0
        while true {
            guard pos + 4 <= f.count else { throw TagError.failed("Damaged FLAC header.") }
            let isLast = f[pos] & 0x80 != 0
            let type = f[pos] & 0x7F
            let len = (Int(f[pos + 1]) << 16) | (Int(f[pos + 2]) << 8) | Int(f[pos + 3])
            let start = pos + 4
            guard start + len <= f.count else { throw TagError.failed("Damaged FLAC header.") }
            blocks.append((type: type, body: Array(f[start..<start + len])))
            pos = start + len
            if isLast { audioStart = pos; break }
        }

        var done = false
        for i in blocks.indices where blocks[i].type == 4 && !done {
            blocks[i].body = try vorbis(updating: blocks[i].body, lrc: lrc)
            done = true
        }
        if !done {
            blocks.append((type: 4, body: build(vendor: Array("NekoLyrics".utf8), comments: [Array("LYRICS=".utf8) + Array(lrc.utf8)])))
        }

        var out = Array("fLaC".utf8)
        for (i, b) in blocks.enumerated() {
            guard b.body.count < 1 << 24 else { throw TagError.failed("Lyrics are too large for a FLAC tag.") }
            out.append(b.type | (i == blocks.count - 1 ? 0x80 : 0))
            out += [UInt8((b.body.count >> 16) & 0xFF), UInt8((b.body.count >> 8) & 0xFF), UInt8(b.body.count & 0xFF)]
            out += b.body
        }
        return out + f[audioStart...]
    }

    private static func vorbis(updating b: [UInt8], lrc: String) throws -> [UInt8] {
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= b.count else { return nil }
            let v = Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
            i += 4
            return v
        }
        guard let vlen = u32(), i + vlen <= b.count else { throw TagError.failed("Damaged FLAC tag.") }
        let vendor = Array(b[i..<i + vlen])
        i += vlen
        guard let count = u32(), count < 100_000 else { throw TagError.failed("Damaged FLAC tag.") }

        var comments: [[UInt8]] = []
        for _ in 0..<count {
            guard let len = u32(), i + len <= b.count else { throw TagError.failed("Damaged FLAC tag.") }
            let raw = Array(b[i..<i + len])
            i += len
            let text = String(decoding: raw, as: UTF8.self)
            if let eq = text.firstIndex(of: "="), lyricKeys.contains(text[..<eq].uppercased()) { continue }
            comments.append(raw)
        }
        comments.append(Array("LYRICS=".utf8) + Array(lrc.utf8))
        return build(vendor: vendor, comments: comments)
    }

    private static func build(vendor: [UInt8], comments: [[UInt8]]) -> [UInt8] {
        var out = le32Bytes(vendor.count) + vendor + le32Bytes(comments.count)
        for c in comments { out += le32Bytes(c.count) + c }
        return out
    }
}

// MARK: - M4A / MP4

private enum MP4Writer {
    typealias Atom = (type: [UInt8], payload: [UInt8])

    enum T {
        static let moov = Array("moov".utf8)
        static let mdat = Array("mdat".utf8)
        static let moof = Array("moof".utf8)
        static let udta = Array("udta".utf8)
        static let meta = Array("meta".utf8)
        static let hdlr = Array("hdlr".utf8)
        static let ilst = Array("ilst".utf8)
        static let data = Array("data".utf8)
        static let lyr: [UInt8] = [0xA9, 0x6C, 0x79, 0x72]    // "©lyr"
        static let trak = Array("trak".utf8)
        static let mdia = Array("mdia".utf8)
        static let minf = Array("minf".utf8)
        static let stbl = Array("stbl".utf8)
        static let stco = Array("stco".utf8)
        static let co64 = Array("co64".utf8)
    }

    typealias TopAtom = (type: [UInt8], start: Int, size: Int)

    static func rewrite(_ f: [UInt8], lrc: String) throws -> [UInt8] {
        let atoms = try topLevel(f)
        if atoms.contains(where: { $0.type == T.moof }) { throw TagError.unsupported("fragmented MP4 files") }
        guard let moov = atoms.first(where: { $0.type == T.moov }) else { throw TagError.failed("No moov atom found.") }
        guard rd32(f, moov.start) != 1 else { throw TagError.unsupported("64-bit moov atoms") }

        let oldPayload = Array(f[(moov.start + 8)..<(moov.start + moov.size)])
        guard var payload = withLyrics(oldPayload, lrc) else {
            throw TagError.unsupported("this MP4 metadata layout")
        }

        // If moov comes BEFORE the audio (mdat), every chunk offset moves by the size change.
        let delta = payload.count + 8 - moov.size
        if let mdat = atoms.first(where: { $0.type == T.mdat }), moov.start < mdat.start, delta != 0 {
            let whole = 0..<payload.count
            guard walkOffsets(&payload, whole, { $0 + delta }) else {
                throw TagError.failed("Couldn't update the MP4 chunk offsets.")
            }
        }

        var out: [UInt8] = Array(f[0..<moov.start])
        out += be32Bytes(payload.count + 8)
        out += T.moov
        out += payload
        out += f[(moov.start + moov.size)...]

        // Sanity check: every chunk offset must land inside an mdat atom of the NEW file.
        let newAtoms = try topLevel(out)
        let mdats = newAtoms.filter { $0.type == T.mdat }
        guard let newMoov = newAtoms.first(where: { $0.type == T.moov }) else { throw TagError.failed("Rebuild failed.") }
        var copy = Array(out[(newMoov.start + 8)..<(newMoov.start + newMoov.size)])
        let copyRange = 0..<copy.count
        let ok = walkOffsets(&copy, copyRange) { v in
            mdats.contains(where: { v >= $0.start + 8 && v < $0.start + $0.size }) ? v : nil
        }
        guard ok else { throw TagError.failed("Chunk offsets check failed, so your file was NOT changed.") }
        return out
    }

    static func topLevel(_ f: [UInt8]) throws -> [TopAtom] {
        var atoms: [TopAtom] = []
        var pos = 0
        while pos + 8 <= f.count {
            var size = rd32(f, pos)
            if size == 1 {
                guard pos + 16 <= f.count else { throw TagError.failed("Damaged MP4 file.") }
                size = (rd32(f, pos + 8) << 32) | rd32(f, pos + 12)
            } else if size == 0 {
                size = f.count - pos
            }
            guard size >= 8, pos + size <= f.count else { throw TagError.failed("Damaged MP4 file.") }
            atoms.append((type: Array(f[pos + 4..<pos + 8]), start: pos, size: size))
            pos += size
        }
        return atoms
    }

    static func children(_ b: [UInt8]) -> [Atom]? {
        var out: [Atom] = []
        var pos = 0
        while pos < b.count {
            guard pos + 8 <= b.count else { return nil }
            let size = rd32(b, pos)
            guard size >= 8, pos + size <= b.count else { return nil }
            out.append((type: Array(b[pos + 4..<pos + 8]), payload: Array(b[pos + 8..<pos + size])))
            pos += size
        }
        return out
    }

    static func serialize(_ atoms: [Atom]) -> [UInt8] {
        var out: [UInt8] = []
        for a in atoms { out += be32Bytes(a.payload.count + 8) + a.type + a.payload }
        return out
    }

    /// moov payload with moov/udta/meta/ilst/©lyr set (created where missing).
    static func withLyrics(_ moov: [UInt8], _ lrc: String) -> [UInt8]? {
        guard var top = children(moov) else { return nil }

        var udta: [Atom] = []
        let udtaI = top.firstIndex { $0.type == T.udta }
        if let i = udtaI {
            guard let k = children(top[i].payload) else { return nil }
            udta = k
        }

        var metaHead: [UInt8] = [0, 0, 0, 0]                    // version + flags
        var meta: [Atom] = []
        let metaI = udta.firstIndex { $0.type == T.meta }
        if let i = metaI {
            let p = udta[i].payload
            guard p.count >= 4, let k = children(Array(p[4...])) else { return nil }
            metaHead = Array(p[0..<4])
            meta = k
        } else {
            let hdlr: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + Array("mdir".utf8) + Array("appl".utf8) + [0, 0, 0, 0, 0, 0, 0, 0, 0]
            meta = [(type: T.hdlr, payload: hdlr)]
        }

        var ilst: [Atom] = []
        let ilstI = meta.firstIndex { $0.type == T.ilst }
        if let i = ilstI {
            guard let k = children(meta[i].payload) else { return nil }
            ilst = k
        }
        ilst.removeAll { $0.type == T.lyr }
        let dataPayload: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0] + Array(lrc.utf8)   // type 1 = UTF-8, locale 0
        ilst.append((type: T.lyr, payload: serialize([(type: T.data, payload: dataPayload)])))
        let ilstPayload = serialize(ilst)

        if let i = ilstI { meta[i].payload = ilstPayload } else { meta.append((type: T.ilst, payload: ilstPayload)) }
        let metaPayload = metaHead + serialize(meta)
        if let i = metaI { udta[i].payload = metaPayload } else { udta.append((type: T.meta, payload: metaPayload)) }
        let udtaPayload = serialize(udta)
        if let i = udtaI { top[i].payload = udtaPayload } else { top.append((type: T.udta, payload: udtaPayload)) }
        return serialize(top)
    }

    /// Visits every chunk offset in stco/co64 tables (moov/trak/mdia/minf/stbl). `transform` returns the
    /// new value, or nil to abort. Returns false on malformed data or abort.
    static func walkOffsets(_ b: inout [UInt8], _ range: Range<Int>, _ transform: (Int) -> Int?) -> Bool {
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            let size = rd32(b, pos)
            guard size >= 8, pos + size <= range.upperBound else { return false }
            let type = Array(b[pos + 4..<pos + 8])
            let body = (pos + 8)..<(pos + size)

            if type == T.trak || type == T.mdia || type == T.minf || type == T.stbl {
                if !walkOffsets(&b, body, transform) { return false }
            } else if type == T.stco {
                guard body.count >= 8 else { return false }
                let n = rd32(b, body.lowerBound + 4)
                guard n >= 0, 8 + n * 4 <= body.count else { return false }
                for k in 0..<n {
                    let at = body.lowerBound + 8 + k * 4
                    guard let v = transform(rd32(b, at)), v >= 0, v <= 0xFFFF_FFFF else { return false }
                    let bytes = be32Bytes(v)
                    for j in 0..<4 { b[at + j] = bytes[j] }
                }
            } else if type == T.co64 {
                guard body.count >= 8 else { return false }
                let n = rd32(b, body.lowerBound + 4)
                guard n >= 0, 8 + n * 8 <= body.count else { return false }
                for k in 0..<n {
                    let at = body.lowerBound + 8 + k * 8
                    let old = (rd32(b, at) << 32) | rd32(b, at + 4)
                    guard let v = transform(old), v >= 0 else { return false }
                    let hi = be32Bytes(v >> 32), lo = be32Bytes(v & 0xFFFF_FFFF)
                    for j in 0..<4 { b[at + j] = hi[j]; b[at + 4 + j] = lo[j] }
                }
            }
            pos += size
        }
        return true
    }
}
