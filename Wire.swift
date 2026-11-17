import Foundation

// Shared by the Mac app and the iPhone viewer: add this file to BOTH targets.

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
}
