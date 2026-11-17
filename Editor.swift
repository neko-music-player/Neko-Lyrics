import AppKit
import SwiftUI

/// Small helper: open a SwiftUI view in a normal window. Menu bar popovers close too easily and
/// don't reliably take keyboard input, so anything you type into lives in a real window.
@MainActor
private func openWindow(title: String, size: NSSize, resizable: Bool = true, content: NSView) -> NSWindow {
    var mask: NSWindow.StyleMask = [.titled, .closable]
    if resizable { mask.insert(.resizable) }
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.contentView = content
    w.center()
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
    return w
}

// MARK: - Edit lyrics text

@MainActor
enum LyricsEditor {
    private static var window: NSWindow?

    static func show(engine: Engine) {
        window?.close()
        let view = LyricsEditorView(engine: engine, text: engine.candidate?.lrc ?? "") {
            LyricsEditor.window?.close()
        }
        window = openWindow(title: "Edit lyrics", size: NSSize(width: 640, height: 560),
                            content: NSHostingView(rootView: view))
    }
}

struct LyricsEditorView: View {
    @ObservedObject var engine: Engine
    @State var text: String
    var close: () -> Void

    private var timedLines: Int { LRC.parse(text, trackEnd: 0).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(engine.track.map { "\($0.title) — \($0.artist)" } ?? "")
                .font(.headline)
            Text("One line per row: [mm:ss.xx]words. Word-level timing is optional: [00:10.00]<00:10.00>Hello <00:10.40>world")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.4))
            HStack {
                Text("\(timedLines) timed lines")
                    .font(.caption)
                    .foregroundStyle(timedLines >= 2 ? Color.secondary : Color.red)
                Spacer()
                Button("Cancel") { close() }
                Button("Save") {
                    engine.saveEdited(text)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(timedLines < 2)
            }
        }
        .padding()
    }
}

// MARK: - Search for lyrics by hand

@MainActor
enum LyricsFinder {
    private static var window: NSWindow?

    static func show(engine: Engine) {
        window?.close()
        engine.openFinder()
        let view = LyricsFinderView(engine: engine,
                                    title: engine.track?.title ?? "",
                                    artist: engine.track?.artist ?? "") {
            LyricsFinder.window?.close()
            engine.closePicker()
        }
        window = openWindow(title: "Find lyrics", size: NSSize(width: 600, height: 640),
                            content: NSHostingView(rootView: view))
    }
}

struct LyricsFinderView: View {
    @ObservedObject var engine: Engine
    @State var title: String
    @State var artist: String
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find lyrics").font(.headline)
            Text("Search as you would on a lyrics site: fix the spelling, drop “feat.” or “Remastered”, try only the title.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Title", text: $title)
                TextField("Artist (optional)", text: $artist)
                Button("Search") { search() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(engine.searching || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)

            status

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(engine.alternatives) { c in card(c) }
                }
            }

            HStack {
                Button("None of these (hide lyrics)") {
                    engine.hideLyrics()
                    close()
                }
                Spacer()
                Button("Close") { close() }
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 480)
    }

    private func search() {
        // Typed text is searched as written; an empty artist means a title-only search.
        engine.searchOnline(title: title, artist: artist)
    }

    @ViewBuilder
    private var status: some View {
        if engine.searching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching…").font(.caption).foregroundStyle(.secondary)
            }
        } else if !engine.pickerMessage.isEmpty {
            Text(engine.pickerMessage).font(.caption).foregroundStyle(.orange)
        } else if !engine.searchSummary.isEmpty {
            Text(engine.searchSummary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card(_ c: LyricsCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.label).font(.callout.bold()).lineLimit(2)
            Text(previewText(c.lrc))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Use these lyrics") {
                    engine.choose(c)
                    close()
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// First few lines of the lyrics, plain text.
    private func previewText(_ lrc: String) -> String {
        LRC.parse(lrc, trackEnd: 0).prefix(4)
            .map { $0.words.map { $0.text }.joined(separator: " ") }
            .joined(separator: "\n")
    }
}
