import SwiftUI

struct ViewerView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        TimelineView(.animation) { _ in
            let t = model.currentTime
            ZStack {
                Color.black.ignoresSafeArea()

                if let i = model.lineIndex(at: t),
                   let last = model.lines[i].words.last, t < last.end + 3 {
                    VStack(spacing: 24) {
                        lineText(model.lines[i], t: t)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        if i + 1 < model.lines.count {
                            lineText(model.lines[i + 1], t: -1)
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .opacity(0.6)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(32)
                } else {
                    Text(model.connected
                         ? (model.title.isEmpty ? "Play something on your Mac" : "♪ \(model.title)")
                         : "Looking for Neko Lyrics on your Mac…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // Keep the phone awake so it works like a lyrics display.
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
    }

    private func lineText(_ line: WireLine, t: Double) -> Text {
        line.words.reduce(Text("")) { acc, w in
            acc + Text(w.text + " ")
                .foregroundColor(t >= w.start ? .yellow : Color.white.opacity(0.35))
        }
    }
}
