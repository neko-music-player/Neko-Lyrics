// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NekoLyrics",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NekoLyrics",
            path: ".",
            exclude: ["README.md", "build.sh", "package.sh", "Info.plist", "iOS", "Assets"],
            sources: [
                "App.swift", "Engine.swift", "Models.swift", "NowPlaying.swift",
                "LyricsProvider.swift", "AppleLyrics.swift", "NewStyles.swift", "MenuGuard.swift", "LRC.swift", "EmbeddedLyrics.swift", "LyricsCache.swift",
                "TagWriter.swift", "Editor.swift", "AlbumArt.swift", "WordGlyphs.swift", "Styles.swift",
                "Overlay.swift", "LockScreenLayer.swift", "Awake.swift", "SettingsView.swift",
                "Wire.swift", "PhoneSync.swift", "Library.swift", "DesktopPlayer.swift",
            ]
        )
    ]
)
