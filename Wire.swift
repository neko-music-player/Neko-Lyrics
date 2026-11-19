import Foundation

// Shared by the Mac app and the iPhone viewer: this file must be the same in BOTH.

struct WireWord: Codable {
    let text: String
    let start: Double
    let end: Double
}

struct WireLine: Codable {
    let words: [WireWord]
    let start: Double
}

enum WireMessage: Codable {
    /// Sent when the track changes and when lyrics finish loading (lines may be empty).
    case lyrics(title: String, artist: String, lines: [WireLine])
    /// Sent every ~1.5s. The phone interpolates between messages.
    case clock(isPlaying: Bool, position: Double)
    /// Album cover (small JPEG) and three colours as [r, g, b] (0...1): highlight, backdrop A, backdrop B.
    case art(jpeg: Data, highlight: [Double], a: [Double], b: [Double])
}
