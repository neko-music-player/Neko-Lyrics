import AppKit
import SwiftUI

/// Colors used by the overlay. Either the three you picked, or derived from album art.
struct Palette: Equatable {
    var lyric: Color        // words already sung
    var highlight: Color    // the word being sung
    var secondary: Color    // words still to come
    var backdropA: Color    // gradient behind the lyrics (Auto Sync only)
    var backdropB: Color
    var isAuto: Bool
    var font = LyricFont()  // family, weight and size (set by the engine; not part of the album art)

    enum WordState { case sung, current, upcoming }

    func color(for state: WordState) -> Color {
        switch state {
        case .sung: return lyric
        case .current: return highlight
        case .upcoming: return secondary
        }
    }
}

enum AlbumArt {
    /// A tiny copy of the cover. Scaled up it looks blurred, which is much cheaper than blurring every frame.
    static func small(_ image: NSImage, side: Int = 48) -> NSImage {
        let size = NSSize(width: side, height: side)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// Cover art of the playing track. Music: via AppleScript. Spotify: downloads its artwork URL.
    @MainActor
    static func image(for track: Track) async -> NSImage? {
        guard NowPlayingMonitor.isRunning(track.source) else { return nil }
        var error: NSDictionary?
        switch track.source {
        case .music:
            let script = NSAppleScript(source: "tell application \"Music\" to return data of artwork 1 of current track")
            guard let d = script?.executeAndReturnError(&error), error == nil else { return nil }
            return NSImage(data: d.data)
        case .spotify:
            let script = NSAppleScript(source: "tell application \"Spotify\" to return artwork url of current track")
            guard let s = script?.executeAndReturnError(&error).stringValue, error == nil,
                  let url = URL(string: s.replacingOccurrences(of: "http://", with: "https://")) else { return nil }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
    }

    /// Picks a vivid main color and a contrasting accent, then builds readable text colors on dark.
    static func palette(from image: NSImage) -> Palette? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 40
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drew else { return nil }

        struct Bucket { var n = 0; var r = 0; var g = 0; var b = 0 }
        var buckets = [Bucket](repeating: Bucket(), count: 4096)
        for p in 0..<(size * size) {
            let r = Int(pixels[p * 4]), g = Int(pixels[p * 4 + 1]), b = Int(pixels[p * 4 + 2])
            if max(r, g, b) < 40 { continue }                        // ignore near-black
            let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)   // 16 levels per channel
            buckets[key].n += 1
            buckets[key].r += r
            buckets[key].g += g
            buckets[key].b += b
        }

        // Score = how common, weighted toward saturated and bright colors.
        var scored: [(score: Double, h: Double, s: Double, v: Double)] = []
        for bk in buckets where bk.n > 0 {
            let c = hsb(Double(bk.r) / Double(bk.n) / 255, Double(bk.g) / Double(bk.n) / 255, Double(bk.b) / Double(bk.n) / 255)
            scored.append((Double(bk.n) * (0.12 + c.s) * (0.35 + c.v), c.h, c.s, c.v))
        }
        scored.sort { $0.score > $1.score }
        guard let main = scored.first else { return nil }

        func hueGap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1 - d) }
        let accent = scored.first { hueGap($0.h, main.h) > 0.1 && $0.score > main.score * 0.15 }
        let h1 = main.h
        let h2 = accent?.h ?? (main.h + 0.08).truncatingRemainder(dividingBy: 1)
        let grey = main.s < 0.12   // grayscale cover: keep it neutral

        return Palette(
            lyric: Color(hue: h1, saturation: grey ? 0 : 0.10, brightness: 1.0),
            highlight: Color(hue: h1, saturation: grey ? 0 : min(max(main.s, 0.45), 0.95), brightness: 1.0),
            secondary: Color(hue: h1, saturation: grey ? 0 : 0.30, brightness: 0.68),
            backdropA: Color(hue: h1, saturation: grey ? 0 : 0.70, brightness: 0.30),
            backdropB: Color(hue: h2, saturation: grey ? 0 : 0.70, brightness: 0.14),
            isAuto: true
        )
    }

    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}


// MARK: - Readability: keep text, highlight and backdrop apart

extension Color {
    fileprivate var srgb: (r: Double, g: Double, b: Double) {
        let c: NSColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// 0 (black) ... 1 (white)
    var luminance: Double {
        let c = srgb
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    /// Distance in RGB, 0 (same) ... about 1.7 (black vs white).
    func distance(to other: Color) -> Double {
        let a = srgb
        let b = other.srgb
        let dr: Double = a.r - b.r
        let dg: Double = a.g - b.g
        let db: Double = a.b - b.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Same hue, but bright and saturated: for glowing light.
    /// 0 = grey / black / white, 1 = fully saturated.
    var saturation: Double {
        let c: NSColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return Double(c.saturationComponent)
    }

    /// Hue / saturation / brightness, each 0...1.
    var hsb: (h: Double, s: Double, b: Double) {
        let c: NSColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return (Double(c.hueComponent), Double(c.saturationComponent), Double(c.brightnessComponent))
    }

    func hueShifted(_ by: Double) -> Color {
        let v = hsb
        var h: Double = v.h + by
        if h < 0 { h += 1.0 }
        if h > 1 { h -= 1.0 }
        return Color(hue: h, saturation: v.s, brightness: v.b)
    }

    var vivid: Color {
        let c: NSColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        // A neutral colour has no hue (it reads as red): leave it alone instead of forcing saturation onto it.
        if c.saturationComponent < 0.12 { return Color(white: max(Double(c.brightnessComponent), 0.85)) }
        let s: Double = max(Double(c.saturationComponent), 0.6)
        let b: Double = max(Double(c.brightnessComponent), 0.9)
        return Color(hue: Double(c.hueComponent), saturation: s, brightness: b)
    }

    fileprivate var hue: Double {
        let c: NSColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return Double(c.hueComponent)
    }
}

extension Palette {
    /// Black or white, whichever reads on top of the highlight color.
    var onHighlight: Color { highlight.luminance > 0.6 ? Color(white: 0.06) : Color.white }

    /// Fixes combinations that vanish: text the same tone as the backdrop, or a highlight that matches
    /// the backdrop or the lyric color. `backdrop` is the backdrop's luminance, 0 (dark) ... 1 (light).
    func fixed(backdrop: Double) -> Palette {
        var p = self
        let light: Bool = backdrop > 0.55

        if abs(p.lyric.luminance - backdrop) < 0.4 {
            p.lyric = light ? Color(white: 0.08) : Color.white
            if !p.isAuto { p.secondary = p.lyric.opacity(0.4) }
        }
        if abs(p.secondary.luminance - backdrop) < 0.12 {
            p.secondary = p.lyric.opacity(0.4)
        }

        let lyric: Color = p.lyric
        func bad(_ c: Color) -> Bool {
            abs(c.luminance - backdrop) < 0.25 || c.distance(to: lyric) < 0.35
        }
        if bad(p.highlight) {
            let h: Double = p.highlight.hue
            let brightness: Double = light ? 0.55 : 1.0
            for shift in [0.5, 0.33, 0.66, 0.17] {
                let hue: Double = (h + shift).truncatingRemainder(dividingBy: 1.0)
                let cand = Color(hue: hue, saturation: 0.85, brightness: brightness)
                if !bad(cand) {
                    p.highlight = cand
                    break
                }
            }
        }
        return p
    }
}
