import SwiftUI

struct ViewerView: View {
    @ObservedObject var model: ViewerModel

    // MARK: Fonts: every song gets its own, the same one every time

    private static let fontPool: [String] = [
        "sys-rounded", "sys-serif", "sys-default",
        "AvenirNext-Heavy", "Georgia-Bold", "Futura-CondensedExtraBold", "MarkerFelt-Wide",
        "ChalkboardSE-Bold", "Optima-ExtraBlack", "Didot-Bold", "Palatino-Bold",
        "Baskerville-Bold", "Copperplate-Bold", "Noteworthy-Bold", "HelveticaNeue-CondensedBlack",
        "TrebuchetMS-Bold", "AvenirNextCondensed-Heavy", "Menlo-Bold"
    ]

    private var songFont: String {
        var h: UInt64 = 5381
        for u in (model.title + "|" + model.artist).unicodeScalars { h = h &* 33 &+ UInt64(u.value) }
        return Self.fontPool[Int(h % UInt64(Self.fontPool.count))]
    }

    private func font(_ size: CGFloat) -> Font {
        switch songFont {
        case "sys-rounded": return .system(size: size, weight: .heavy, design: .rounded)
        case "sys-serif": return .system(size: size, weight: .bold, design: .serif)
        case "sys-default": return .system(size: size, weight: .heavy)
        default: return .custom(songFont, size: size)
        }
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { tl in
                background(clock: tl.date.timeIntervalSinceReferenceDate)
            }
            VStack(spacing: 0) {
                header
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    lyricsList(t: model.currentTime)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // behaves like a lyrics display
            model.start()
        }
    }

    // MARK: Background: the cover, blurred, over a slowly drifting colour wash

    private func background(clock: Double) -> some View {
        ZStack {
            LinearGradient(colors: [model.backdropA, model.backdropB], startPoint: .top, endPoint: .bottom)
            if let cover = model.cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.7 + 0.05 * sin(clock * 0.15))
                    .rotationEffect(.degrees(sin(clock * 0.07) * 5))
                    .blur(radius: 60)
                    .opacity(0.6)
            }
            Circle()
                .fill(model.highlight.opacity(0.25))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: CGFloat(sin(clock * 0.2)) * 110, y: CGFloat(cos(clock * 0.17)) * 220)
            Color.black.opacity(0.3)
        }
        .ignoresSafeArea()
    }

    // MARK: Header: small cover, title, artist

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let cover = model.cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5)))
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: model.highlight.opacity(0.4), radius: 10, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title.isEmpty ? "Neko Lyrics" : model.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(model.artist.isEmpty ? (model.connected ? "Play something on your Mac" : "Looking for your Mac…") : model.artist)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(model.connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    // MARK: Lyrics: the whole song scrolls, the current line is bright and fills word by word

    @ViewBuilder
    private func lyricsList(t: Double) -> some View {
        let cur = model.lineIndex(at: t)
        if model.lines.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: 90)
                        ForEach(model.lines.indices, id: \.self) { i in
                            lineRow(i, current: cur, t: t)
                                .id(i)
                        }
                        Color.clear.frame(height: 360)
                    }
                    .padding(.horizontal, 24)
                }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                           .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .onChange(of: cur) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.7)) {
                        proxy.scrollTo(new, anchor: UnitPoint(x: 0.5, y: 0.32))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            if let cover = model.cover {
                Image(uiImage: cover)
                    .resizable().scaledToFill()
                    .frame(width: 240, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: model.highlight.opacity(0.5), radius: 30, y: 12)
            }
            Text(model.connected ? (model.title.isEmpty ? "Play something on your Mac" : "♪") : "Looking for Neko Lyrics on your Mac…")
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func lineRow(_ i: Int, current: Int?, t: Double) -> some View {
        let line = model.lines[i]
        let dist = current.map { abs(i - $0) } ?? 99
        if i == current {
            WordFlow(spacing: 9, lineSpacing: 6) {
                ForEach(line.words.indices, id: \.self) { k in
                    word(line.words[k], t: t)
                }
            }
            .transition(.opacity)
        } else {
            WordFlow(spacing: 9, lineSpacing: 6) {
                ForEach(line.words.indices, id: \.self) { k in
                    Text(line.words[k].text)
                        .font(font(30))
                }
            }
            .foregroundStyle(.white)
            .opacity(dist == 1 ? 0.5 : (dist == 2 ? 0.38 : 0.28))
            .blur(radius: dist <= 1 ? 0 : min(Double(dist) * 0.8, 3.2))
            .scaleEffect(0.94, anchor: .leading)
        }
    }

    private func word(_ w: WireWord, t: Double) -> some View {
        let span = max(w.end - w.start, 0.12)
        let p = min(max((t - w.start) / span, 0), 1)
        let sung = t >= w.end
        let active = t >= w.start && !sung
        return Text(w.text)
            .font(font(30))
            .foregroundStyle(.white.opacity(sung ? 1 : 0.38))
            .overlay(alignment: .leading) {
                Text(w.text)
                    .font(font(30))
                    .foregroundStyle(model.highlight)
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: CGFloat(sung ? 0 : p), anchor: .leading)
                    }
                    .opacity(sung ? 0 : 1)
            }
            .shadow(color: model.highlight.opacity(active ? 0.75 : 0), radius: active ? 12 : 0)
            .offset(y: active ? -2 : 0)
            .animation(.easeOut(duration: 0.18), value: active)
    }
}

/// Words flow left to right and wrap, left-aligned like a lyrics sheet.
struct WordFlow: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 8

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]]
        var x: CGFloat = 0
        for i in subviews.indices {
            let w = subviews[i].sizeThatFits(.unspecified).width
            if x + w > width, !out[out.count - 1].isEmpty {
                out.append([])
                x = 0
            }
            out[out.count - 1].append(i)
            x += w + spacing
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var height: CGFloat = 0
        for row in rows(subviews, width: width) {
            height += (row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0) + lineSpacing
        }
        return CGSize(width: width, height: max(height - lineSpacing, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            var x = bounds.minX
            let rowHeight = sizes.map(\.height).max() ?? 0
            for (n, i) in row.enumerated() {
                subviews[i].place(at: CGPoint(x: x, y: y + (rowHeight - sizes[n].height) / 2), proposal: .unspecified)
                x += sizes[n].width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}
