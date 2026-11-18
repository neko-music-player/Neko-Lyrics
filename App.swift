import SwiftUI

@main
struct NekoLyricsApp: App {
    // Engine starts monitoring in init, so lyrics work even if the menu is never opened.
    @StateObject private var engine = Engine()

    init() {
        Self.firstRunDefaults()
        // Debug helper: NekoLyrics --inspect "/path/to/song.mp3"
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--inspect"), i + 1 < args.count {
            Inspect.run(path: args[i + 1])
            exit(0)
        }
    }

    /// One time only: turn the visible features on, so a fresh install actually shows something.
    private static func firstRunDefaults() {
        let d = UserDefaults.standard
        if d.object(forKey: "setupV2") == nil {
            d.set("poster", forKey: "style")           // the new default look
            d.set(true, forKey: "playerShowsLyrics")
            d.set(false, forKey: "lyricsAboveApps")
            d.set(true, forKey: "setupV2")
        }
        if d.string(forKey: "artwork") == "fullscreen" {      // merged into Background
            d.set("fullArtwork", forKey: "background")
            d.set("none", forKey: "artwork")
        }
        guard d.object(forKey: "setupV1") == nil else { return }
        d.set(false, forKey: "lockedOnly")           // lyrics on the desktop too, not only the lock screen
        d.set("transparent", forKey: "background")   // nothing dimming your apps
        d.set(true, forKey: "playerOpen")
        d.set(true, forKey: "liveWallpaper")
        d.set(true, forKey: "edgeLight")
        d.set(true, forKey: "lyricsEnabled")
        d.set("rise", forKey: "style")
        d.set(true, forKey: "setupV1")
    }

    /// The Neko head as a template image (follows light/dark menu bars); falls back to a music symbol.
    private static let menuIcon: NSImage = {
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        let fallback = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Neko Lyrics") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()

    var body: some Scene {
        MenuBarExtra {
            SettingsView(engine: engine)
        } label: {
            Image(nsImage: Self.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
