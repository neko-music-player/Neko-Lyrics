import SwiftUI
import Combine
import MultipeerConnectivity

/// What the screen watches: the song, its lyrics, the cover and the playback clock mirrored from the Mac.
final class ViewerModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var lines: [WireLine] = []
    @Published var connected = false
    @Published var cover: UIImage?
    @Published var highlight = Color.yellow
    @Published var backdropA = Color(red: 0.12, green: 0.1, blue: 0.25)
    @Published var backdropB = Color(red: 0.02, green: 0.02, blue: 0.06)

    private var isPlaying = false
    private var anchorPos = 0.0
    private var anchorDate = Date()
    private var link: PeerLink?
    private var lastHeard = Date.distantPast

    func start() {
        guard link == nil else { return }
        link = PeerLink(owner: self)
        link?.start()
    }

    var currentTime: Double {
        isPlaying ? anchorPos + Date().timeIntervalSince(anchorDate) : anchorPos
    }

    func lineIndex(at t: Double) -> Int? {
        lines.lastIndex { $0.start <= t }
    }

    private func color(_ v: [Double]) -> Color {
        v.count == 3 ? Color(red: v[0], green: v[1], blue: v[2]) : .white
    }

    fileprivate func apply(_ message: WireMessage) {
        // Any message proves the Mac is there, even if the connection state callback flickered.
        lastHeard = Date()
        if !connected { connected = true }
        switch message {
        case let .lyrics(title, artist, lines):
            if title != self.title { cover = nil }
            self.title = title
            self.artist = artist
            self.lines = lines
        case let .clock(isPlaying, position):
            self.isPlaying = isPlaying
            self.anchorPos = position
            self.anchorDate = Date()
        case let .art(jpeg, highlight, a, b):
            cover = UIImage(data: jpeg)
            self.highlight = color(highlight)
            backdropA = color(a)
            backdropB = color(b)
        }
    }

    fileprivate func setConnected(_ value: Bool) {
        // Ignore a "disconnected" callback while messages are still arriving.
        if !value && Date().timeIntervalSince(lastHeard) < 6 { return }
        connected = value
    }
}

/// Talks to the Mac. Kept separate from the model above.
private final class PeerLink: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate {
    private weak var owner: ViewerModel?
    private let peer = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
    private lazy var browser = MCNearbyServiceBrowser(peer: peer, serviceType: "nekolyrics")

    init(owner: ViewerModel) { self.owner = owner }

    func start() {
        session.delegate = self
        browser.delegate = self
        browser.startBrowsingForPeers()
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.owner?.setConnected(state == .connected)
            if state == .notConnected {
                self.browser.stopBrowsingForPeers()
                self.browser.startBrowsingForPeers()
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        DispatchQueue.main.async { self.owner?.apply(message) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
