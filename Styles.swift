import AppKit
import SwiftUI

typealias WordState = Palette.WordState

// MARK: - Font

/// Family, weight and size multiplier for the lyrics.
struct LyricFont: Equatable {
    static let roundedID = "system-rounded"
    static let systemID = "system"
    static let serifID = "system-serif"
    static let monoID = "system-mono"

    static let weights: [(name: String, weight: Font.Weight)] = [
        ("Light", .light), ("Regular", .regular), ("Medium", .medium), ("Semibold", .semibold),
        ("Bold", .bold), ("Heavy", .heavy), ("Black", .black),
    ]
    static let defaultWeightIndex = 4   // Bold

    var family = LyricFont.roundedID
    var weightIndex = LyricFont.defaultWeightIndex
    var scale = 1.0

    var weight: Font.Weight {
        Self.weights[min(max(weightIndex, 0), Self.weights.count - 1)].weight
    }

    func font(_ size: CGFloat) -> Font {
        let s = size * CGFloat(scale)
        switch family {
        case Self.roundedID: return .system(size: s, weight: weight, design: .rounded)
        case Self.systemID: return .system(size: s, weight: weight, design: .default)
        case Self.serifID: return .system(size: s, weight: weight, design: .serif)
        case Self.monoID: return .system(size: s, weight: weight, design: .monospaced)
        default: return Font.custom(family, size: s).weight(weight)
        }
    }
}

struct FontChoice: Identifiable {
    let id: String
    let name: String
}

enum FontChoices {
    /// The four built-in designs, then every font family installed on this Mac.
    static let all: [FontChoice] = {
        var list = [
            FontChoice(id: LyricFont.roundedID, name: "System Rounded"),
            FontChoice(id: LyricFont.systemID, name: "System"),
            FontChoice(id: LyricFont.serifID, name: "Serif"),
            FontChoice(id: LyricFont.monoID, name: "Monospaced"),
        ]
        list += NSFontManager.shared.availableFontFamilies.sorted().map { FontChoice(id: $0, name: $0) }
        return list
    }()
}

// MARK: - Styles

/// How each word reacts while it is sung.
enum WordEffect {
    case standard, karaoke, bounce, typewriter, neon
}

enum LyricStyle: String, CaseIterable, Identifiable {
    case random, poster, rise, stack, stackVisual, electric, classic, karaoke, bounce, typewriter, neon, smooth, spotlight, ship, fisheye, fisheyeVisual, visual, constellation, sway

    var id: String { rawValue }

    var title: String {
        switch self {
        case .random: return "Random per song"
        case .poster: return "Poster (chunky words)"
        case .rise: return "Rise (one line at a time)"
        case .stack: return "Stack (marker)"
        case .stackVisual: return "Stack + icons"
        case .electric: return "Electric"
        case .classic: return "Classic"
        case .karaoke: return "Karaoke fill"
        case .bounce: return "Bounce"
        case .typewriter: return "Typewriter"
        case .neon: return "Neon glow"
        case .smooth: return "Smooth blur"
        case .spotlight: return "Spotlight"
        case .ship: return "Ship"
        case .fisheye: return "Fisheye"
        case .fisheyeVisual: return "Fisheye Visual"
        case .visual: return "Visual"
        case .constellation: return "Constellation (twinkling stars)"
        case .sway: return "Sway (back and forth)"
        }
    }

    /// Styles "Random per song" chooses from.
    static let randomPool: [LyricStyle] = [.stack, .stackVisual, .electric, .fisheye, .fisheyeVisual, .ship,
                                           .smooth, .spotlight, .karaoke, .neon, .bounce, .visual, .constellation, .sway]

    var usesIcons: Bool { self == .visual || self == .fisheyeVisual || self == .stackVisual }

    var effect: WordEffect {
        switch self {
        case .karaoke: return .karaoke
        case .bounce: return .bounce
        case .typewriter: return .typewriter
        case .neon: return .neon
        default: return .standard
        }
    }
}

/// Where each word of a line is in the song right now.
func wordStates(_ line: Line, at t: TimeInterval) -> [WordState] {
    if t >= line.end { return Array(repeating: .sung, count: line.words.count) }
    guard let active = line.words.lastIndex(where: { $0.start <= t }) else {
        return Array(repeating: .upcoming, count: line.words.count)
    }
    return line.words.indices.map { $0 < active ? WordState.sung : ($0 == active ? .current : .upcoming) }
}

// MARK: - Layout that wraps words onto rows

struct FlowLayout: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 8
    var centered = true

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(in maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, sv) in subviews.enumerated() {
            let size = sv.sizeThatFits(.unspecified)
            let last = rows.count - 1
            if !rows[last].items.isEmpty, rows[last].width + spacing + size.width > maxWidth {
                rows.append(Row())
            }
            let l = rows.count - 1
            rows[l].width += (rows[l].items.isEmpty ? 0 : spacing) + size.width
            rows[l].height = max(rows[l].height, size.height)
            rows[l].items.append((index: i, size: size))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = rows(in: proposal.width ?? .infinity, subviews)
        let height = r.reduce(0) { $0 + $1.height } + CGFloat(max(r.count - 1, 0)) * lineSpacing
        let width = min(r.map { $0.width }.max() ?? 0, proposal.width ?? .infinity)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews) {
            var x = bounds.minX + (centered ? (bounds.width - row.width) / 2 : 0)
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}

// MARK: - Words

struct GlyphView: View {
    let glyph: Glyph
    let size: CGFloat

    var body: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size, weight: .bold))
        case .emoji(let e):
            Text(e).font(.system(size: size))
        }
    }
}

struct WordChip: View {
    let word: Word
    let state: WordState
    let t: TimeInterval
    let palette: Palette
    let size: CGFloat
    let icons: Bool
    let effect: WordEffect

    private var age: Double { t - word.start }
    private var duration: Double { max(word.end - word.start, 0.15) }

    var body: some View {
        HStack(spacing: size * 0.15) {
            label
            if icons, let g = word.glyph {
                // Always takes up its space, so words don't jump when the icon appears.
                GlyphView(glyph: g, size: size * 0.8)
                    .foregroundColor(palette.highlight)
                    .opacity(state == .upcoming ? 0 : 1)
                    .scaleEffect(state == .upcoming ? 0.3 : 1)
            }
        }
        .scaleEffect(popScale)
        .offset(y: lift)
    }

    /// Short pop when the word starts.
    private var popScale: CGFloat {
        guard state == .current else { return 1 }
        let fade = CGFloat(max(0, 1 - age / 0.3))
        switch effect {
        case .bounce: return 1 + 0.18 * fade
        case .standard: return 1 + 0.14 * fade
        default: return 1 + 0.04 * fade
        }
    }

    /// Bounce: the word jumps up and settles back.
    private var lift: CGFloat {
        guard effect == .bounce, state == .current, age >= 0, age < 0.45 else { return 0 }
        return -size * 0.32 * CGFloat(sin(Double.pi * age / 0.45))
    }

    @ViewBuilder
    private var label: some View {
        let font = palette.font.font(size)
        switch effect {
        case .karaoke: karaoke(font)
        case .typewriter: typewriter(font)
        case .neon: neon(font)
        case .standard, .bounce: plain(font)
        }
    }

    private func plain(_ font: Font) -> some View {
        Text(word.text)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .foregroundColor(palette.color(for: state))
            .shadow(color: state == .current ? palette.highlight.opacity(0.7) : .clear, radius: size * 0.25)
    }

    /// The highlight color wipes across the word as it is sung.
    private func karaoke(_ font: Font) -> some View {
        let p: Double = state == .sung ? 1 : (state == .current ? min(max(age / duration, 0), 1) : 0)
        return Text(word.text)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .foregroundColor(palette.secondary)
            .overlay(alignment: .leading) {
                Text(word.text)
                    .font(font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .foregroundColor(palette.highlight)
                    .mask(alignment: .leading) {
                        GeometryReader { g in
                            Rectangle().frame(width: g.size.width * p)
                        }
                    }
            }
            .shadow(color: state == .upcoming ? .clear : palette.highlight.opacity(0.35), radius: size * 0.15)
    }

    /// Letters appear one by one.
    private func typewriter(_ font: Font) -> some View {
        let count = word.text.count
        let n: Int
        switch state {
        case .sung: n = count
        case .upcoming: n = 0
        case .current: n = Int((min(max(age / (duration * 0.7), 0), 1) * Double(count)).rounded(.up))
        }
        return Text(word.text)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .opacity(0)                                   // reserves the word's full width
            .overlay(alignment: .leading) {
                Text(String(word.text.prefix(n)))
                    .font(font)
                    .lineLimit(1)
                    .foregroundColor(state == .current ? palette.highlight : palette.lyric)
            }
    }

    /// Bright core with a colored glow that flickers on the current word and fades after it.
    private func neon(_ font: Font) -> some View {
        let glow: Double
        switch state {
        case .current: glow = 0.9 + 0.1 * sin(t * 40)
        case .sung: glow = min(1, max(0.25, 1 - (t - word.end) / 2.5))
        case .upcoming: glow = 0
        }
        return Text(word.text)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .foregroundColor(state == .upcoming ? palette.secondary : palette.lyric)
            .shadow(color: palette.highlight.opacity(0.9 * glow), radius: size * 0.10)
            .shadow(color: palette.highlight.opacity(0.7 * glow), radius: size * 0.32)
    }
}

struct FlowLineView: View {
    let line: Line
    let t: TimeInterval
    let palette: Palette
    let size: CGFloat
    let icons: Bool
    var effect: WordEffect = .standard
    var centered = true

    var body: some View {
        let states = wordStates(line, at: t)
        FlowLayout(spacing: size * 0.3, lineSpacing: size * 0.15, centered: centered) {
            ForEach(line.words.indices, id: \.self) { i in
                WordChip(word: line.words[i], state: states[i], t: t, palette: palette,
                         size: size, icons: icons, effect: effect)
            }
        }
    }
}

// MARK: - Classic / Karaoke / Bounce / Typewriter / Neon / Visual: current line big, next line small

struct ClassicStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette
    let icons: Bool
    let effect: WordEffect

    var body: some View {
        let lines = engine.lines
        let idx = engine.lineIndex(at: t)
        ZStack {
            if let i = idx, let last = lines[i].words.last, t < last.end + 4 {
                VStack(spacing: 36) {
                    FlowLineView(line: lines[i], t: t, palette: palette, size: 64, icons: icons, effect: effect)
                    if i + 1 < lines.count {
                        FlowLineView(line: lines[i + 1], t: t, palette: palette, size: 34, icons: false)
                            .opacity(0.7)
                    }
                }
                .padding(80)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(i)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: idx)
    }
}

// MARK: - Smooth blur: left-aligned scrolling list, current line sharp, the rest blurred

struct SmoothStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette

    var body: some View {
        let lines = engine.lines
        let pos = engine.scrollPosition(at: t)
        let center = Int(pos.rounded())
        GeometryReader { geo in
            let rowH = max(130, geo.size.height / 6.5)
            ZStack {
                ForEach((center - 5)...(center + 5), id: \.self) { i in
                    if i >= 0 && i < lines.count {
                        SmoothRow(line: lines[i], t: t, palette: palette,
                                  d: Double(i) - pos, rowH: rowH, size: geo.size)
                    }
                }
            }
        }
    }
}

private struct SmoothRow: View {
    let line: Line
    let t: TimeInterval
    let palette: Palette
    let d: Double
    let rowH: CGFloat
    let size: CGSize

    var body: some View {
        let ad: Double = abs(d)
        let scale: CGFloat = CGFloat(1.0 - min(ad * 0.07, 0.3))
        let blurR: CGFloat = CGFloat(min(ad * 2.6, 9.0))
        let alpha: Double = ad < 0.5 ? 1.0 : max(0.25, 0.7 - ad * 0.12)
        let px: CGFloat = size.width / 2
        let py: CGFloat = size.height / 2 + CGFloat(d) * rowH

        let row = FlowLineView(line: line, t: t, palette: palette, size: 52, icons: false, centered: false)
            .frame(width: size.width * 0.72, alignment: .leading)
        row
            .scaleEffect(scale, anchor: .leading)
            .blur(radius: blurR)
            .opacity(alpha)
            .position(x: px, y: py)
    }
}

// MARK: - Spotlight: the current word, big and simple, with the whole line small underneath

struct SpotlightStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette

    var body: some View {
        let lines = engine.lines
        if let li = engine.lineIndex(at: t), let last = lines[li].words.last, t < last.end + 4 {
            let line = lines[li]
            let active = line.words.lastIndex(where: { $0.start <= t }) ?? 0
            let state = wordStates(line, at: t)[active]
            let full = line.words.map { $0.text }.joined(separator: " ")
            VStack(spacing: 44) {
                WordChip(word: line.words[active], state: state, t: t, palette: palette,
                         size: 190, icons: false, effect: .standard)
                    .id(line.words[active].id)
                Text(full)
                    .font(palette.font.font(36))
                    .foregroundColor(palette.lyric.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Fisheye: a stack of lines bulging toward you around the current one

struct FisheyeStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette
    let icons: Bool

    /// Degrees of tilt per row of distance. If the stack looks bent the wrong way
    /// (hollow instead of bulging), flip the sign.
    private let tiltPerRow: Double = -24

    var body: some View {
        let lines = engine.lines
        let pos = engine.scrollPosition(at: t)
        let center = Int(pos.rounded())
        GeometryReader { geo in
            ZStack {
                ForEach((center - 4)...(center + 4), id: \.self) { i in
                    if i >= 0 && i < lines.count {
                        FisheyeRow(line: lines[i], t: t, palette: palette, icons: icons,
                                   d: Double(i) - pos, tilt: tiltPerRow, size: geo.size)
                    }
                }
            }
        }
    }
}

private struct FisheyeRow: View {
    let line: Line
    let t: TimeInterval
    let palette: Palette
    let icons: Bool
    let d: Double
    let tilt: Double
    let size: CGSize

    var body: some View {
        let d2: Double = d * d
        let scaleD: Double = 0.42 + 0.88 * exp(-d2 / 1.4)      // magnified in the middle
        let scale: CGFloat = CGFloat(scaleD)
        let alpha: Double = 0.18 + 0.82 * exp(-d2 / 3.0)
        let angle: Double = max(-62.0, min(62.0, d * tilt))
        let norm: Double = max(-1.0, min(1.0, d / 3.4))
        let offsetY: Double = Double(size.height) * 0.36 * sin(norm * Double.pi / 2.0)   // rows bunch up at the edges
        let y: CGFloat = size.height * 0.5 + CGFloat(offsetY)
        let px: CGFloat = size.width / 2

        let base = FlowLineView(line: line, t: t, palette: palette, size: 46, icons: icons)
            .frame(width: size.width * 0.78)
        base
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
            .opacity(alpha)
            .position(x: px, y: y)
    }
}

// MARK: - Ship: a wall of lyrics drifting in 3D

struct ShipStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette
    let icons: Bool
    let clock: Double

    var body: some View {
        let lines = engine.lines
        let pos = engine.scrollPosition(at: t)
        let center = Int(pos.rounded())
        let yaw: Double = sin(clock * 0.23) * 16
        let pitch: Double = sin(clock * 0.17 + 1.3) * 8
        let roll: Double = sin(clock * 0.11 + 0.4) * 2.5
        GeometryReader { geo in
            let rowH: CGFloat = geo.size.height / 7.5
            ZStack {
                ForEach((center - 5)...(center + 5), id: \.self) { i in
                    if i >= 0 && i < lines.count {
                        ShipRow(line: lines[i], t: t, palette: palette, icons: icons,
                                d: Double(i) - pos, index: i, clock: clock, rowH: rowH, width: geo.size.width)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
            .rotation3DEffect(.degrees(roll), axis: (x: 0, y: 0, z: 1))
        }
    }
}

private struct ShipRow: View {
    let line: Line
    let t: TimeInterval
    let palette: Palette
    let icons: Bool
    let d: Double
    let index: Int
    let clock: Double
    let rowH: CGFloat
    let width: CGFloat

    var body: some View {
        let ad: Double = abs(d)
        let fontSize: CGFloat = ad < 0.5 ? 46 : 34
        let scale: CGFloat = CGFloat(1.0 - min(ad * 0.05, 0.3))
        let phase: Double = clock * 0.5 + Double(index) * 0.9
        let dxD: Double = sin(phase) * 22.0
        let dx: CGFloat = CGFloat(dxD)
        let dy: CGFloat = CGFloat(d) * rowH
        let alpha: Double = 1.0 - min(ad / 6.0, 0.8)

        let base = FlowLineView(line: line, t: t, palette: palette, size: fontSize, icons: icons)
            .frame(width: width * 0.82)
        base
            .scaleEffect(scale)
            .offset(x: dx, y: dy)
            .opacity(alpha)
    }
}


// MARK: - Backdrop modes

enum BackdropMode: String, CaseIterable, Identifiable {
    case transparent, dim, gradient, cover, animated, coverAnimated, fullArtwork
    var id: String { rawValue }
    var title: String {
        switch self {
        case .transparent: return "Transparent"
        case .dim: return "Dim"
        case .gradient: return "Color gradient"
        case .cover: return "Album cover"
        case .animated: return "Animated colors"
        case .coverAnimated: return "Cover + animated"
        case .fullArtwork: return "Full-screen artwork (animated)"
        }
    }
    var usesCover: Bool { self == .cover || self == .coverAnimated || self == .fullArtwork }
}

// MARK: - Stack: one word per row, current word magnified with a marker block behind it

enum StableHash {
    /// Same input, same number, every launch (unlike Swift's Hasher).
    static func value(_ text: String, salt: UInt64) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325 &+ salt &* 0x100000001b3
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

/// How the stack of words moves.
enum StackVariant: String, CaseIterable {
    case swing, topple, turn, bounce, slide
}

enum StackMotion: String, CaseIterable, Identifiable {
    case random, swing, topple, turn, bounce, slide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .random: return "Random per song"
        case .swing: return "Swing (side to side)"
        case .topple: return "Topple (fall back and away)"
        case .turn: return "Turn away (flip sideways)"
        case .bounce: return "Bounce (hop up)"
        case .slide: return "Slide in"
        }
    }
    var variant: StackVariant? { StackVariant(rawValue: rawValue) }
}

struct StackStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette
    let icons: Bool
    let variant: StackVariant

    var body: some View {
        let lines = engine.lines
        if let li = engine.lineIndex(at: t) {
            let from = max(0, li - 1)
            let to = min(lines.count - 1, li + 2)
            let flow = StackFlow.build(lines: lines, from: from, to: to, current: li, t: t)
            GeometryReader { geo in
                ZStack {
                    ForEach(flow.words.indices, id: \.self) { i in
                        let d: Double = Double(i) - flow.pos
                        if abs(d) < 4.3 {
                            StackWordRow(word: flow.words[i], index: flow.firstIndex + i,
                                         state: StackFlow.state(i, flow.current),
                                         t: t, palette: palette, icons: icons, variant: variant,
                                         d: d, size: geo.size)
                        }
                    }
                }
            }
        }
    }
}

enum StackFlow {
    struct Result { var words: [Word]; var current: Int; var pos: Double; var firstIndex: Int }

    static func build(lines: [Line], from: Int, to: Int, current li: Int, t: TimeInterval) -> Result {
        var words: [Word] = []
        var cur = 0
        for l in from...to {
            for (k, w) in lines[l].words.enumerated() {
                if l == li && k == 0 { cur = words.count }
                if l == li && w.start <= t { cur = words.count }
                words.append(w)
            }
        }
        let age: Double = max(0, t - words[cur].start)
        let p: Double = min(age / 0.3, 1.0)
        let ease: Double = p * p * (3 - 2 * p)
        let before: Int = lines[..<from].reduce(0) { $0 + $1.words.count }
        return Result(words: words, current: cur, pos: Double(cur - 1) + ease, firstIndex: before)
    }

    static func state(_ i: Int, _ cur: Int) -> Palette.WordState {
        i < cur ? .sung : (i == cur ? .current : .upcoming)
    }
}

/// Everything a row needs to be drawn, worked out in one place.
private struct StackLook {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1
    var angleX: Double = 0
    var angleY: Double = 0
    var alpha: Double = 1
    var blur: Double = 0
}

private enum StackMath {
    /// +1 tilts the top of a row away from the viewer. Flip to -1 if "topple" falls toward you instead.
    static let tiltSign: Double = 1

    /// Pseudo-random but stable +1 / -1 per word.
    static func sign(_ index: Int, salt: Int) -> Double {
        let h: UInt64 = StableHash.value(String(index), salt: UInt64(salt))
        return h % 2 == 0 ? 1.0 : -1.0
    }

    static func look(variant: StackVariant, d: Double, age: Double, index: Int, size: CGSize) -> StackLook {
        let w: Double = Double(size.width)
        let h: Double = Double(size.height)
        let d2: Double = d * d
        let rowH: Double = h / 5.0
        let live: Bool = age >= 0
        let entry: Double = live ? max(0.0, 1.0 - age / 0.55) : 0.0     // 1 at the start of a word, 0 after 0.55 s
        let dirX: Double = sign(index, salt: 11)

        var l = StackLook()
        l.scale = 0.4 + 0.6 * exp(-d2 / 0.9)
        l.alpha = 0.15 + 0.85 * exp(-d2 / 2.2)
        l.blur = min(abs(d) * 1.2, 5.0)
        l.y = rowH * d * (0.62 + 0.38 * exp(-d2))
        l.angleX = max(-50.0, min(50.0, d * -16.0))

        let e2: Double = entry * entry
        switch variant {
        case .swing:
            let ring: Double = live && age < 2.0 ? dirX * w * 0.12 * exp(-age * 4.5) * sin(age * 16.0) : 0.0
            l.x = dirX * w * 0.04 * exp(-d2 / 1.5) + ring
        case .topple:
            // Like dominoes: each word is sung upright, then falls backward as the next one arrives.
            if d < 0 {
                l.angleX = StackMath.tiltSign * min(64.0, -d * 42.0)
                l.y = rowH * d * 1.1
                l.scale *= 0.92
            } else {
                l.angleX = StackMath.tiltSign * -min(14.0, d * 7.0)
            }
            l.angleX += StackMath.tiltSign * -58.0 * e2      // the new word swings up from leaning back
            l.y += h * 0.05 * e2
        case .turn:
            let dirY: Double = sign(index, salt: 23)
            l.angleX = 0
            if d < 0 {                                   // sung words turn their back on us and drift up
                l.angleY = dirY * min(62.0, -d * 40.0)
                l.y = rowH * d * 1.1
                l.x = dirY * w * 0.03 * -d
            }
            l.angleY += dirY * 78.0 * e2                 // the new word spins in from the side
        case .bounce:
            l.angleX = max(-30.0, min(30.0, d * -8.0))
            if live && age < 1.2 { l.y -= sin(age * 14.0) * exp(-age * 5.5) * h * 0.06 }
            l.scale *= 1.0 + 0.18 * e2
        case .slide:
            if live && age < 0.6 {
                let r: Double = 1.0 - age / 0.6
                l.x = dirX * w * 0.5 * r * r * r
            }
        }
        return l
    }
}

private struct StackWordRow: View {
    let word: Word
    let index: Int
    let state: Palette.WordState
    let t: TimeInterval
    let palette: Palette
    let icons: Bool
    let variant: StackVariant
    let d: Double
    let size: CGSize

    var body: some View {
        let base: CGFloat = min(size.height * 0.2, 170)
        let look: StackLook = StackMath.look(variant: variant, d: d, age: t - word.start, index: index, size: size)
        let px: CGFloat = size.width / 2 + CGFloat(look.x)
        let py: CGFloat = size.height / 2 + CGFloat(look.y)

        content(base: base)
            .scaleEffect(CGFloat(look.scale))
            .rotation3DEffect(.degrees(look.angleX), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .rotation3DEffect(.degrees(look.angleY), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .blur(radius: CGFloat(look.blur))
            .opacity(look.alpha)
            .position(x: px, y: py)
    }

    @ViewBuilder
    private func content(base: CGFloat) -> some View {
        let isCurrent: Bool = state == .current
        let dur: Double = max(word.end - word.start, 0.15)
        let rawProg: Double = (t - word.start) / dur * 2.5
        let prog: CGFloat = CGFloat(min(max(rawProg, 0.0), 1.0))   // marker fills in the first 40 %
        let age: Double = t - word.start
        let pop: CGFloat = isCurrent ? 1 + 0.12 * CGFloat(max(0, 1 - age / 0.25)) : 1
        let textColor: Color = isCurrent ? palette.onHighlight : (state == .sung ? palette.lyric : palette.secondary)

        HStack(spacing: base * 0.18) {
            Text(word.text)
                .font(palette.font.font(base))
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, base * 0.14)
                .background(alignment: .leading) {
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: base * 0.1)
                            .fill(palette.highlight)
                            .frame(width: g.size.width * (isCurrent ? prog : 0))
                    }
                }
            if icons, let g = word.glyph {
                GlyphView(glyph: g, size: base * 0.5)
                    .foregroundColor(palette.highlight)
                    .opacity(state == .upcoming ? 0.4 : 1)
            }
        }
        .frame(maxWidth: size.width * 0.9)
        .scaleEffect(pop)
    }
}

// MARK: - Artwork modes

enum ArtworkMode: String, CaseIterable, Identifiable {
    case none, cover, animated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Off"
        case .cover: return "Still"
        case .animated: return "Animated"
        }
    }
    /// A card beside the lyrics.
    var isCard: Bool { self != .none }
}


// MARK: - Electric: crackling bolts of light run through the word as it is sung

struct ElectricStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette

    var body: some View {
        let lines = engine.lines
        if let li = engine.lineIndex(at: t) {
            let line = lines[li]
            let active: Int = line.words.lastIndex(where: { $0.start <= t }) ?? 0
            let word = line.words[active]
            let age: Double = max(0, t - word.start)
            let power: Double = exp(-age * 3.5)
            let full = line.words.map { $0.text }.joined(separator: " ")
            ZStack {
                ElectricBolts(t: t, power: power, color: palette.highlight, seed: active + li * 31)
                VStack(spacing: 40) {
                    ElectricWord(text: word.text, power: power, t: t, color: palette.highlight, font: palette.font)
                    Text(full)
                        .font(palette.font.font(34))
                        .foregroundColor(palette.lyric.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(80)
            }
        }
    }
}

private struct ElectricWord: View {
    let text: String
    let power: Double
    let t: TimeInterval
    let color: Color
    let font: LyricFont

    var body: some View {
        let jitter: CGFloat = CGFloat(sin(t * 90.0) * power * 5.0)
        let glow: CGFloat = CGFloat(14.0 + 40.0 * power)
        Text(text)
            .font(font.font(190))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .shadow(color: color, radius: glow)
            .shadow(color: color.opacity(0.8), radius: glow * 0.4)
            .offset(x: jitter)
    }
}

private struct BoltRNG {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}

private enum BoltGeometry {
    /// Jagged line between two points (midpoint displacement).
    static func points(from a: CGPoint, to b: CGPoint, amp: Double, rng: inout BoltRNG) -> [CGPoint] {
        var pts: [CGPoint] = [a, b]
        var amplitude: Double = amp
        for _ in 0..<6 {
            var next: [CGPoint] = []
            for i in 0..<(pts.count - 1) {
                let p = pts[i]
                let q = pts[i + 1]
                let dx: Double = Double(q.x - p.x)
                let dy: Double = Double(q.y - p.y)
                let len: Double = max(sqrt(dx * dx + dy * dy), 0.001)
                let nx: Double = -dy / len
                let ny: Double = dx / len
                let shift: Double = (rng.next() - 0.5) * 2.0 * amplitude
                let mid = CGPoint(x: (p.x + q.x) / 2 + CGFloat(nx * shift),
                                  y: (p.y + q.y) / 2 + CGFloat(ny * shift))
                next.append(p)
                next.append(mid)
            }
            next.append(pts[pts.count - 1])
            pts = next
            amplitude *= 0.55
        }
        return pts
    }

    static func path(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }
}

private struct ElectricBolts: View {
    let t: TimeInterval
    let power: Double
    let color: Color
    let seed: Int

    var body: some View {
        Canvas { ctx, size in
            let frame: Int = Int(t * 24.0)
            var rng = BoltRNG(state: UInt64(truncatingIfNeeded: frame &* 7919 &+ seed &* 104729 &+ 1))
            let cy: CGFloat = size.height * 0.5
            let strength: Double = 0.3 + 0.7 * power
            let amp: Double = Double(size.height) * (0.05 + 0.08 * strength)

            for k in 0..<3 {
                let kShift: CGFloat = CGFloat(k - 1)
                let yShift: CGFloat = kShift * size.height * 0.05
                let a = CGPoint(x: 0, y: cy + yShift)
                let b = CGPoint(x: size.width, y: cy + yShift)
                let pts = BoltGeometry.points(from: a, to: b, amp: amp, rng: &rng)
                let path = BoltGeometry.path(pts)
                let flicker: Double = 0.55 + 0.45 * rng.next()
                let alpha: Double = strength * flicker

                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 10))
                    layer.stroke(path, with: .color(color.opacity(alpha * 0.9)), lineWidth: 14)
                }
                ctx.stroke(path, with: .color(color.opacity(alpha)), lineWidth: 4)
                ctx.stroke(path, with: .color(Color.white.opacity(min(1.0, alpha + 0.2))), lineWidth: 1.5)

                // a short side branch
                if k == 1, pts.count > 8 {
                    let at = pts[Int(rng.next() * Double(pts.count - 4)) + 2]
                    let end = CGPoint(x: at.x + CGFloat((rng.next() - 0.5) * 300),
                                      y: at.y + CGFloat((rng.next() - 0.5) * 360))
                    let branch = BoltGeometry.path(BoltGeometry.points(from: at, to: end, amp: amp * 0.35, rng: &rng))
                    ctx.stroke(branch, with: .color(color.opacity(alpha * 0.8)), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}


// MARK: - Rise: lines float up onto the screen one at a time

struct RiseStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette

    var body: some View {
        let lines = engine.lines
        if let li = engine.lineIndex(at: t) {
            GeometryReader { geo in
                ZStack {
                    ForEach(max(0, li - 2)...min(lines.count - 1, li + 1), id: \.self) { i in
                        RiseRow(line: lines[i], t: t, palette: palette, rel: i - li, size: geo.size)
                    }
                }
            }
        }
    }
}

private struct RiseRow: View {
    let line: Line
    let t: TimeInterval
    let palette: Palette
    let rel: Int            // -2, -1 = already sung, 0 = now, 1 = next
    let size: CGSize

    private struct Look { var y = 0.0; var alpha = 1.0; var blur = 0.0; var scale = 1.0 }

    private func look() -> Look {
        let age: Double = max(0, t - line.start)
        let p: Double = min(age / 0.7, 1.0)
        let ease: Double = 1.0 - pow(1.0 - p, 3.0)           // ease-out
        let rowH: Double = Double(size.height) * 0.17
        var l = Look()
        // The line being sung rises from below; finished lines float up and fade.
        switch rel {
        case 0:
            l.y = (1.0 - ease) * rowH * 1.2
            l.alpha = ease
            l.blur = (1.0 - ease) * 10.0
        case 1:
            l.y = rowH * 1.3
            l.alpha = 0.35
            l.blur = 3.0
            l.scale = 0.7
        default:
            let up: Double = Double(-rel)
            l.y = -rowH * up * 1.1
            l.alpha = max(0.0, 0.55 - up * 0.25)
            l.blur = up * 3.0
            l.scale = 0.8
        }
        return l
    }

    var body: some View {
        let l: Look = look()
        FlowLineView(line: line, t: t, palette: palette, size: rel == 0 ? 78 : 56, icons: false)
            .frame(width: size.width * 0.82)
            .scaleEffect(CGFloat(l.scale))
            .blur(radius: CGFloat(l.blur))
            .opacity(l.alpha)
            .position(x: size.width / 2, y: size.height / 2 + CGFloat(l.y))
    }
}

// MARK: - Edge light: a glowing frame around the screen that pulses with the words

struct EdgeLightView: View {
    let colors: [Color]
    let clock: Double
    let kick: Double
    let thickness: Double
    let glow: Double
    var radius: Double = 14

    /// 1 at the screen edge, falling smoothly to 0: an eased curve, so there is no visible band or hard edge.
    private func fade(_ strength: Double) -> Gradient {
        var stops: [Gradient.Stop] = []
        for i in 0...10 {
            let x: Double = Double(i) / 10.0
            let a: Double = pow(1.0 - x, 2.4) * strength
            stops.append(Gradient.Stop(color: Color.white.opacity(a), location: CGFloat(x)))
        }
        return Gradient(stops: stops)
    }

    /// The album colors, flowing slowly along an edge; seamless because the list repeats once.
    private func flow(_ horizontal: Bool, _ cols: [Color]) -> LinearGradient {
        let phase: Double = (clock * 0.045).truncatingRemainder(dividingBy: 1.0)
        let list: [Color] = cols + cols + [cols[0]]
        let start: UnitPoint = horizontal ? UnitPoint(x: -phase, y: 0.5) : UnitPoint(x: 0.5, y: -phase)
        let end: UnitPoint = horizontal ? UnitPoint(x: 2.0 - phase, y: 0.5) : UnitPoint(x: 0.5, y: 2.0 - phase)
        return LinearGradient(colors: list, startPoint: start, endPoint: end)
    }

    var body: some View {
        let cols: [Color] = colors.isEmpty ? [Color.white] : colors.map { $0.vivid }
        let depthBase: Double = 40.0 + thickness * 5.0
        let depth: CGFloat = CGFloat(depthBase * (1.0 + 0.25 * kick))
        let strength: Double = min(1.0, glow * (0.75 + 0.35 * kick))
        let mask = fade(strength)
        GeometryReader { g in
            ZStack {
                Rectangle().fill(flow(true, cols))
                    .mask(LinearGradient(gradient: mask, startPoint: .top, endPoint: .bottom))
                    .frame(width: g.size.width, height: depth)
                    .position(x: g.size.width / 2, y: depth / 2)
                Rectangle().fill(flow(true, cols.reversed()))
                    .mask(LinearGradient(gradient: mask, startPoint: .bottom, endPoint: .top))
                    .frame(width: g.size.width, height: depth)
                    .position(x: g.size.width / 2, y: g.size.height - depth / 2)
                Rectangle().fill(flow(false, cols))
                    .mask(LinearGradient(gradient: mask, startPoint: .leading, endPoint: .trailing))
                    .frame(width: depth, height: g.size.height)
                    .position(x: depth / 2, y: g.size.height / 2)
                Rectangle().fill(flow(false, cols.reversed()))
                    .mask(LinearGradient(gradient: mask, startPoint: .trailing, endPoint: .leading))
                    .frame(width: depth, height: g.size.height)
                    .position(x: g.size.width - depth / 2, y: g.size.height / 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(radius), style: .continuous))
        }
        .allowsHitTesting(false)
    }
}


/// Tiny sparks that drift inward from the screen edge and twinkle out; brighter on each word.
private struct EdgeSparkles: View {
    let colors: [Color]
    let clock: Double
    let kick: Double

    private func frac(_ x: Double) -> Double { x - floor(x) }

    var body: some View {
        Canvas { ctx, size in
            let reach: Double = Double(min(size.width, size.height)) * 0.09
            for i in 0..<22 {
                let f: Double = Double(i)
                let seed: Double = frac(sin(f * 12.9898) * 43758.5453)
                let along: Double = frac(sin(f * 78.233) * 43758.5453)
                let phase: Double = frac(sin(f * 37.719) * 43758.5453)
                let life: Double = frac(clock * 0.1 * (0.6 + seed) + phase)
                let inward: CGFloat = CGFloat(life * reach)
                let side: Int = Int(along * 4.0) % 4
                let u: CGFloat = CGFloat(frac(along * 4.0))
                var p = CGPoint.zero
                switch side {
                case 0: p = CGPoint(x: u * size.width, y: inward)
                case 1: p = CGPoint(x: size.width - inward, y: u * size.height)
                case 2: p = CGPoint(x: (1 - u) * size.width, y: size.height - inward)
                default: p = CGPoint(x: inward, y: (1 - u) * size.height)
                }
                let alpha: Double = sin(life * Double.pi) * (0.35 + 0.65 * kick)
                let r: CGFloat = CGFloat(1.2 + 2.0 * seed)
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(colors[i % colors.count].opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Poster: chunky words that pop in one under another, wobbling, with the last chunk ghosting away

enum PosterFont {
    /// Cooper Black if installed, else the nearest chunky slab / serif.
    static let family: String = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        for name in ["Cooper Black", "Cooper Std", "Rockwell Extra Bold", "Rockwell", "Georgia"] where installed.contains(name) {
            return name
        }
        return ""
    }()

    static func font(_ size: CGFloat, user: LyricFont) -> Font {
        // Keep the chosen font if you picked a specific one; the default rounded font gets the poster look.
        if user.family != LyricFont.roundedID { return user.font(size) }
        let s: CGFloat = size * CGFloat(user.scale)
        if family.isEmpty { return .system(size: s, weight: .black, design: .serif) }
        return Font.custom(family, size: s).weight(.black)
    }
}

enum PosterChunks {
    /// Groups of up to 4 words; a comma / full stop ends a group once it has 2 words.
    static func split(_ words: [Word]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for i in words.indices {
            let count: Int = i - start + 1
            let w: String = words[i].text
            let punct: Bool = w.hasSuffix(",") || w.hasSuffix(".") || w.hasSuffix("?") || w.hasSuffix("!")
            if count >= 4 || (punct && count >= 2) {
                out.append(start..<(i + 1))
                start = i + 1
            }
        }
        if start < words.count { out.append(start..<words.count) }
        return out
    }
}

struct PosterStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette

    var body: some View {
        let lines = engine.lines
        if let li = engine.lineIndex(at: t) {
            let line = lines[li]
            let active: Int = line.words.lastIndex(where: { $0.start <= t }) ?? 0
            let started: Bool = t >= line.words[active].start
            let chunks = PosterChunks.split(line.words)
            let ci: Int = chunks.firstIndex(where: { $0.contains(active) }) ?? 0
            let range = chunks[ci]
            let shown: [Word] = started ? Array(line.words[range.lowerBound...active]) : []
            let chunkStart: Double = line.words[range.lowerBound].start
            let prev: [Word] = previousChunk(lines: lines, li: li, ci: ci, chunks: chunks)
            let lastEnd: Double = line.words[line.words.count - 1].end
            let idle: Double = active == line.words.count - 1 ? max(0, t - lastEnd - 2.0) : 0   // long gap: fade out
            let alpha: Double = max(0, 1.0 - idle)
            let ghost: Double = max(0, 1.0 - (t - chunkStart) / 0.7)

            GeometryReader { g in
                let size: CGFloat = min(g.size.height * 0.11, 130)
                ZStack {
                    if !prev.isEmpty && ghost > 0 {
                        PosterColumn(words: prev, t: t, palette: palette, size: size, ghost: true, motion: .flat)
                            .opacity(ghost * ghost * 0.3)
                            .blur(radius: ghostBlur(ghost))
                            .offset(y: ghostLift(ghost, rows: prev.count, size: size))
                    }
                    PosterColumn(words: shown, t: t, palette: palette, size: size, ghost: false, motion: engine.posterMotion)
                }
                .frame(width: g.size.width, height: g.size.height)
                .opacity(alpha)
            }
        }
    }

    private func ghostBlur(_ g: Double) -> CGFloat {
        let v: Double = (1.0 - g) * 8.0 + 2.0
        return CGFloat(v)
    }

    /// The old chunk rises clear of the new one instead of sitting underneath it.
    private func ghostLift(_ g: Double, rows: Int, size: CGFloat) -> CGFloat {
        let rowH: Double = Double(size) * 0.88
        let base: Double = (Double(rows) / 2.0 + 2.2) * rowH
        let v: Double = base * (0.75 + 0.25 * (1.0 - g))
        return CGFloat(-v)
    }

    private func previousChunk(lines: [Line], li: Int, ci: Int, chunks: [Range<Int>]) -> [Word] {
        if ci > 0 { return Array(lines[li].words[chunks[ci - 1]]) }
        guard li > 0 else { return [] }
        let before = lines[li - 1].words
        guard let last = PosterChunks.split(before).last else { return [] }
        return Array(before[last])
    }
}

enum PosterMotion {
    case flat, topple, turn

    /// +1 tips the top of a word away from the viewer. Flip to -1 if topple falls toward you.
    static let tiltSign: Double = 1
}

private struct PosterColumn: View {
    let words: [Word]
    let t: TimeInterval
    let palette: Palette
    let size: CGFloat
    let ghost: Bool
    let motion: PosterMotion

    var body: some View {
        let n: Int = words.count
        ZStack {
            ForEach(words.indices, id: \.self) { i in
                PosterWord(word: words[i], next: i + 1 < n ? words[i + 1] : nil, row: i, count: n,
                           t: t, palette: palette, size: size, current: !ghost && i == n - 1,
                           ghost: ghost, motion: motion)
            }
        }
    }
}

private struct PosterLook {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1
    var rotX: Double = 0
    var rotY: Double = 0
    var rotZ: Double = 0
    var alpha: Double = 1
    var blur: Double = 0
}

private struct PosterWord: View {
    let word: Word
    let next: Word?
    let row: Int
    let count: Int
    let t: TimeInterval
    let palette: Palette
    let size: CGFloat
    let current: Bool
    let ghost: Bool
    let motion: PosterMotion

    private func look() -> PosterLook {
        var l = PosterLook()
        let age: Double = max(0, t - word.start)
        let p: Double = min(age / 0.32, 1.0)
        let c1: Double = 1.70158
        let back: Double = 1.0 + (c1 + 1.0) * pow(p - 1.0, 3.0) + c1 * pow(p - 1.0, 2.0)   // ease-out-back
        let rowH: Double = Double(size) * 0.88
        let y0: Double = (Double(row) - Double(count - 1) / 2.0) * rowH
        let h: UInt64 = StableHash.value(word.text + String(Int(word.start * 100)), salt: 5)
        let sgn: Double = h % 2 == 0 ? 1.0 : -1.0

        l.y = y0
        l.scale = 0.5 + 0.5 * back
        l.rotZ = sgn * 10.0 * (1.0 - p)
        l.alpha = min(1.0, age / 0.1 + 0.15)

        if ghost || motion == .flat { return l }

        let behind: Int = count - 1 - row            // 0 = the newest word
        if behind > 0, let nx = next {
            // Older words tip back, away from us, as each new word arrives.
            let since: Double = max(0, t - nx.start)
            let fall: Double = Double(min(behind, 3) - 1) + min(1.0, since / 0.4)
            if motion == .topple {
                l.rotX = min(60.0, fall * 36.0 + 8.0)
                l.y -= fall * 22.0
                l.scale *= 1.0 - 0.1 * fall
                l.alpha *= 1.0 - 0.24 * fall
                l.blur = fall * 0.8
            } else {
                let dir: Double = StableHash.value(word.text, salt: 9) % 2 == 0 ? 1.0 : -1.0
                l.rotY = dir * min(75.0, fall * 40.0 + 10.0)
                l.x = dir * fall * 24.0
                l.y -= fall * 12.0
                l.scale *= 1.0 - 0.08 * fall
                l.alpha *= 1.0 - 0.2 * fall
            }
        } else if behind == 0 {
            // The newest word snaps upright from tipped-over.
            let q: Double = 1.0 - p
            if motion == .topple { l.rotX = -40.0 * q * q } else { l.rotY = sgn * 70.0 * q * q }
        }
        return l
    }

    /// Only the word being sung wobbles; older words are plain text (much cheaper to draw).
    @ViewBuilder
    private func letters(color: Color) -> some View {
        let font: Font = PosterFont.font(size, user: palette.font)
        if current {
            WavyText(text: word.text, t: t, font: font, color: color, amp: Double(size) * 0.03)
        } else {
            Text(word.text).font(font).foregroundColor(color).lineLimit(1)
        }
    }

    var body: some View {
        let l: PosterLook = look()
        let h: UInt64 = StableHash.value(word.text + String(Int(word.start * 100)), salt: 5)
        let slant: CGFloat = h % 3 == 0 ? -0.22 : 0
        let color: Color = current ? palette.highlight : palette.lyric

        letters(color: color)
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: 0, ty: 0))
            .scaleEffect(CGFloat(l.scale))
            .rotationEffect(.degrees(l.rotZ))
            .rotation3DEffect(.degrees(l.rotX * PosterMotion.tiltSign), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(l.rotY), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .blur(radius: CGFloat(l.blur))
            .opacity(l.alpha)
            .offset(x: CGFloat(l.x), y: CGFloat(l.y))
            .shadow(color: Color.black.opacity(0.4), radius: 8, y: 3)
    }
}

/// Letters that wobble up and down and tilt slightly, like the lyric videos.
private struct WavyText: View {
    let text: String
    let t: TimeInterval
    let font: Font
    let color: Color
    let amp: Double

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { pair in
                let ph: Double = Double(pair.offset)
                let dy: CGFloat = CGFloat(sin(t * 4.2 + ph * 0.9) * amp)
                let rot: Double = sin(t * 3.1 + ph * 1.3) * 4.0
                Text(String(pair.element))
                    .font(font)
                    .foregroundColor(color)
                    .offset(y: dy)
                    .rotationEffect(.degrees(rot))
            }
        }
        .lineLimit(1)
    }
}


// MARK: - Line: whole-line effect, used when the lyrics only have line timing

struct LineStyleView: View {
    let engine: Engine
    let t: TimeInterval
    let palette: Palette

    var body: some View {
        let lines = engine.lines
        if let li = engine.lineIndex(at: t) {
            let line = lines[li]
            let age: Double = max(0, t - line.start)
            let p: Double = min(age / 0.5, 1.0)
            let ease: Double = 1.0 - pow(1.0 - p, 3.0)
            let last: Double = line.words.last?.end ?? line.end
            let idle: Double = max(0, t - last - 2.5)                       // long gap: fade out
            let fade: Double = max(0, 1.0 - idle)
            GeometryReader { g in
                let size: CGFloat = min(g.size.height * 0.085, 80)
                VStack(spacing: size * 0.55) {
                    row(li - 1, size: size * 0.62, alpha: 0.28 * (1.0 - ease * 0.3), lines: lines)
                    row(li, size: size, alpha: 0.3 + 0.7 * ease, lines: lines)
                        .offset(y: CGFloat((1.0 - ease) * 26.0))
                        .scaleEffect(CGFloat(0.95 + 0.05 * ease))
                    row(li + 1, size: size * 0.62, alpha: 0.34, lines: lines)
                }
                .frame(width: g.size.width, height: g.size.height)
                .opacity(fade)
            }
        }
    }

    @ViewBuilder
    private func row(_ i: Int, size: CGFloat, alpha: Double, lines: [Line]) -> some View {
        if i >= 0 && i < lines.count {
            let text: String = lines[i].words.map { $0.text }.joined(separator: " ")
            let current: Bool = i == engine.lineIndex(at: t)
            Text(text)
                .font(palette.font.font(size))
                .foregroundColor(current ? palette.lyric : palette.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size * 0.8)
                .opacity(alpha)
        } else {
            Color.clear.frame(height: size)
        }
    }
}
