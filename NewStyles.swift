import SwiftUI
import Foundation

// MARK: - Constellation: words are stars that twinkle on, joined by thin lines as they are sung

struct ConstellationStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette
    let clock: Double

    private func rnd(_ key: String, _ salt: UInt64) -> Double {
        Double(StableHash.value(key, salt: salt) % 10_000) / 10_000.0
    }

    /// Where each word of a line sits. Every line picks its own shape (zig-zag, arc, wave, diagonal,
    /// scatter or ring), the same every time for that line, so the sky keeps changing.
    private func points(_ lineIndex: Int, count n: Int, in size: CGSize) -> [CGPoint] {
        var out: [CGPoint] = []
        let w: CGFloat = size.width
        let h: CGFloat = size.height
        let usable: CGFloat = w * 0.78
        let pattern: Int = Int(rnd("pat\(lineIndex)", 9) * 6.0) % 6
        let flip: CGFloat = rnd("flip\(lineIndex)", 10) > 0.5 ? 1 : -1
        let rows: Int = n > 8 ? 3 : 2
        for k in 0..<n {
            let key: String = "\(lineIndex)-\(k)"
            let frac: CGFloat = (CGFloat(k) + 0.5) / CGFloat(max(n, 1))
            let jitterX: CGFloat = CGFloat(rnd(key, 1) - 0.5) * (usable / CGFloat(max(n, 1))) * 0.5
            var x: CGFloat = w * 0.11 + usable * frac + jitterX
            var y: CGFloat = h * 0.5
            switch pattern {
            case 0:
                let lane: CGFloat = CGFloat(k % rows) - CGFloat(rows - 1) / 2.0
                y += lane * h * 0.17
            case 1:
                y += (0.5 - CGFloat(sin(Double(frac) * Double.pi))) * h * 0.36 * flip
            case 2:
                y += CGFloat(sin(Double(frac) * Double.pi * 2.0)) * h * 0.15 * flip
            case 3:
                y += (frac - 0.5) * h * 0.4 * flip + CGFloat(rnd(key, 11) - 0.5) * h * 0.06
            case 4:
                y += CGFloat(rnd(key, 12) - 0.5) * h * 0.42
            default:
                let a: Double = Double(frac) * Double.pi * 2.0 + rnd("rot\(lineIndex)", 13) * 6.28
                x = w * 0.5 + CGFloat(cos(a)) * w * 0.30
                y += CGFloat(sin(a)) * h * 0.22
            }
            y += CGFloat(rnd(key, 2) - 0.5) * h * 0.06
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }

    /// Gentle floating, plus a fly-in: each star arrives from its own direction when its word starts.
    private func drift(_ p: CGPoint, _ k: Int, age: Double = 10.0, line: Int = 0) -> CGPoint {
        let a: Double = Double(k) * 1.3
        var dx: CGFloat = CGFloat(sin(clock * 0.5 + a) * 6.0)
        var dy: CGFloat = CGFloat(cos(clock * 0.43 + a) * 6.0)
        if age < 0.8 {
            let e: Double = pow(1.0 - max(age, 0.0) / 0.8, 3.0)
            let ang: Double = rnd("in\(line)-\(k)", 14) * 6.28
            dx += CGFloat(cos(ang) * 160.0 * e)
            dy += CGFloat(sin(ang) * 110.0 * e)
        }
        return CGPoint(x: p.x + dx, y: p.y + dy)
    }

    var body: some View {
        GeometryReader { g in
            let lines = engine.lines
            let li: Int = engine.lineIndex(at: t) ?? -1
            ZStack {
                Canvas { ctx, size in
                    drawSky(ctx, size)
                    if li >= 0 { drawLines(&ctx, size, index: li, fade: 1.0) }
                    if li >= 1 { drawLines(&ctx, size, index: li - 1, fade: fadeOut(li - 1)) }
                }
                if li >= 1 { lineWords(li - 1, in: g.size, fade: fadeOut(li - 1), lines: lines) }
                if li >= 0 { lineWords(li, in: g.size, fade: 1.0, lines: lines) }
            }
        }
    }

    private func fadeOut(_ i: Int) -> Double {
        let lines = engine.lines
        guard i >= 0, i < lines.count else { return 0 }
        let gone: Double = t - lines[i].end
        return max(0.0, 1.0 - gone / 1.4) * 0.6
    }

    private func drawSky(_ ctx: GraphicsContext, _ size: CGSize) {
        for i in 0..<70 {
            let key: String = "sky\(i)"
            let x: CGFloat = CGFloat(rnd(key, 3)) * size.width
            let y: CGFloat = CGFloat(rnd(key, 4)) * size.height
            let r: CGFloat = CGFloat(0.8 + rnd(key, 5) * 1.6)
            let tw: Double = 0.5 + 0.5 * sin(clock * (0.8 + rnd(key, 6) * 1.6) + rnd(key, 7) * 6.28)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.1 + 0.4 * tw)))
        }
    }

    private func drawLines(_ ctx: inout GraphicsContext, _ size: CGSize, index: Int, fade: Double) {
        let lines = engine.lines
        guard index >= 0, index < lines.count, fade > 0.01 else { return }
        let words = lines[index].words
        let pts: [CGPoint] = points(index, count: words.count, in: size).enumerated().map { drift($0.element, $0.offset, age: t - words[$0.offset].start, line: index) }
        for k in 0..<words.count {
            let age: Double = t - words[k].start
            guard age >= 0 else { continue }
            if k > 0 {
                let p: Double = min(age / 0.45, 1.0)
                let a: CGPoint = pts[k - 1]
                let b: CGPoint = pts[k]
                let end = CGPoint(x: a.x + (b.x - a.x) * CGFloat(p), y: a.y + (b.y - a.y) * CGFloat(p))
                var path = Path()
                path.move(to: a)
                path.addLine(to: end)
                ctx.stroke(path, with: .color(palette.highlight.opacity(0.45 * fade)), lineWidth: 1.2)
            }
            // The star itself, with a four-point sparkle while it twinkles on.
            let tw: Double = age < 1.0 ? exp(-age * 4.0) : 0.0
            let c: CGPoint = pts[k]
            let r: CGFloat = 3.0 + CGFloat(tw) * 3.0
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(Color.white.opacity((0.55 + 0.45 * tw) * fade)))
            if tw > 0.05 {
                let len: CGFloat = 10.0 + CGFloat(tw) * 22.0
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - len, y: c.y)); cross.addLine(to: CGPoint(x: c.x + len, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - len)); cross.addLine(to: CGPoint(x: c.x, y: c.y + len))
                ctx.stroke(cross, with: .color(palette.highlight.opacity(tw * fade)), lineWidth: 1.4)
            }
        }
    }

    @ViewBuilder
    private func lineWords(_ index: Int, in size: CGSize, fade: Double, lines: [Line]) -> some View {
        if index >= 0, index < lines.count, fade > 0.01 {
            let words = lines[index].words
            let pts: [CGPoint] = points(index, count: words.count, in: size)
            let fontSize: CGFloat = min(size.height * 0.07, 58)
            ZStack {
                ForEach(0..<words.count, id: \.self) { k in
                    star(word: words[k], k: k, at: drift(pts[k], k, age: t - words[k].start, line: index), fontSize: fontSize, fade: fade)
                }
            }
        }
    }

    private func star(word: Word, k: Int, at p: CGPoint, fontSize: CGFloat, fade: Double) -> some View {
        let age: Double = t - word.start
        let lit: Bool = age >= 0
        let tw: Double = lit && age < 1.0 ? exp(-age * 4.0) : 0.0
        let pulse: Double = 0.5 + 0.5 * sin(age * 38.0)
        let scale: CGFloat = lit ? CGFloat(1.0 + 0.3 * tw * pulse) : 0.9
        let opacity: Double = (lit ? 1.0 : 0.2) * fade
        let color: Color = lit ? (tw > 0.2 ? palette.highlight : palette.lyric) : palette.secondary
        return Text(word.text)
            .font(palette.font.font(fontSize))
            .foregroundColor(color)
            .shadow(color: palette.highlight.opacity(tw * 0.9), radius: CGFloat(4.0 + 16.0 * tw))
            .scaleEffect(scale)
            .opacity(opacity)
            .position(x: p.x, y: p.y - fontSize * 0.9)
    }
}

// MARK: - Sway: lines swing in from alternating sides and keep rocking gently, back and forth

struct SwayStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette
    let clock: Double

    var body: some View {
        let lines = engine.lines
        if let li = engine.lineIndex(at: t) {
            GeometryReader { g in
                let size: CGFloat = min(g.size.height * 0.1, 92)
                let dir: Double = li % 2 == 0 ? 1.0 : -1.0
                let age: Double = max(0, t - lines[li].start)
                let p: Double = min(age / 0.7, 1.0)
                let inv: Double = 1.0 - p
                // Overshoot spring: arrives from the side, passes the middle, settles.
                let slide: Double = inv * inv * cos(p * 5.0) * Double(g.size.width) * 0.55
                let rock: Double = sin(clock * 1.1 + Double(li)) * Double(g.size.width) * 0.02
                let tilt: Double = dir * inv * 7.0 + sin(clock * 0.8 + Double(li)) * 1.2
                VStack(spacing: size * 0.5) {
                    other(li - 1, size: size * 0.6, dir: -dir, lines: lines, push: p)
                    current(lines[li], size: size)
                        .offset(x: CGFloat(dir * slide + rock))
                        .rotationEffect(.degrees(tilt))
                    other(li + 1, size: size * 0.6, dir: -dir, lines: lines, push: 1.0)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }

    private func current(_ line: Line, size: CGFloat) -> some View {
        let states: [WordState] = wordStates(line, at: t)
        var text = Text("")
        for k in 0..<line.words.count {
            let c: Color = palette.color(for: states[k])
            text = text + Text(line.words[k].text + " ").foregroundColor(c)
        }
        return text
            .font(palette.font.font(size))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, size * 0.8)
            .shadow(color: Color.black.opacity(0.35), radius: 6)
    }

    @ViewBuilder
    private func other(_ i: Int, size: CGFloat, dir: Double, lines: [Line], push: Double) -> some View {
        if i >= 0 && i < lines.count {
            let text: String = lines[i].words.map { $0.text }.joined(separator: " ")
            let sway: Double = sin(clock * 0.9 + Double(i)) * 18.0
            Text(text)
                .font(palette.font.font(size))
                .foregroundColor(palette.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size)
                .opacity(0.3)
                .offset(x: CGFloat(dir * (1.0 - push) * 60.0 + sway))
        } else {
            Color.clear.frame(height: size)
        }
    }
}

// MARK: - Romanization (Japanese, Korean, Hindi/Nepali, Arabic, Russian, Thai ...)

enum Romanizer {
    static func needsRomanization(_ s: String) -> Bool {
        for u in s.unicodeScalars where u.value > 0x24F && u.properties.isAlphabetic { return true }
        return false
    }

    /// One line of text in Latin letters. Japanese uses the system's Japanese reader (kanji readings);
    /// other scripts use the system transliterator. Always a best effort, never perfect.
    static func romanize(_ s: String) -> String {
        guard needsRomanization(s) else { return s }
        let hasKana: Bool = s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        if hasKana, let jp = japanese(s) { return jp }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        return (m as String).replacingOccurrences(of: "  ", with: " ")
    }

    private static func japanese(_ s: String) -> String? {
        let cf: CFString = s as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let tok = CFStringTokenizerCreate(nil, cf, range, kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var out = ""
        var last: Int = 0
        let ns = s as NSString
        var got = false
        while CFStringTokenizerAdvanceToNextToken(tok).rawValue != 0 {
            let r: CFRange = CFStringTokenizerGetCurrentTokenRange(tok)
            if r.location > last { out += ns.substring(with: NSRange(location: last, length: r.location - last)) }
            let raw: String = ns.substring(with: NSRange(location: r.location, length: r.length))
            var piece: String = raw
            if let attr = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String {
                piece = attr
                got = true
            }
            if !out.isEmpty && !out.hasSuffix(" ") { out += " " }
            out += piece
            last = r.location + r.length
        }
        if last < ns.length { out += ns.substring(from: last) }
        guard got else { return nil }
        let m = NSMutableString(string: out)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        return (m as String).trimmingCharacters(in: .whitespaces)
    }

    private static let tag = try! NSRegularExpression(pattern: "<\\d+:\\d+(?:[.:,]\\d+)?>")

    /// Romanizes the words of an LRC text, leaving every timestamp where it is.
    static func convertLRC(_ text: String) -> String {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var rest = Substring(raw)
            var stamps = ""
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                stamps += rest[...close]
                rest = rest[rest.index(after: close)...]
            }
            let body = String(rest)
            guard needsRomanization(body) else { out.append(raw); continue }
            let ns = body as NSString
            let matches = tag.matches(in: body, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                out.append(stamps + romanize(body))
                continue
            }
            // Word-timed line: romanize the text after each <time> tag, keep the tags.
            var s = ""
            var cursor = 0
            for (i, m) in matches.enumerated() {
                if m.range.location > cursor { s += romanize(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))) }
                s += ns.substring(with: m.range)
                cursor = m.range.location + m.range.length
                let next: Int = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
                if next > cursor {
                    let seg: String = ns.substring(with: NSRange(location: cursor, length: next - cursor))
                    let r: String = romanize(seg.trimmingCharacters(in: .whitespaces))
                    s += r.isEmpty ? seg : r + " "
                    cursor = next
                }
            }
            out.append(stamps + s)
        }
        return out.joined(separator: "\n")
    }
}
