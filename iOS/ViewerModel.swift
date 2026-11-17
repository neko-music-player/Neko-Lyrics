import SwiftUI
import MultipeerConnectivity

/// Finds the Neko Lyrics Mac app on the local network and mirrors its lyrics + clock.
final class ViewerModel: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate {
    @Published var title = ""
    @Published var artist = ""
    @Published var lines: [WireLine] = []
    @Published var connected = false

    private var isPlaying = false
    private var anchorPos = 0.0
    private var anchorDate = Date()

    private let peer = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
    private lazy var browser = MCNearbyServiceBrowser(peer: peer, serviceType: "nekolyrics")

    func start() {
        session.delegate = self
        browser.delegate = self
        browser.startBrowsingForPeers()
    }

    var currentTime: Double {
        isPlaying ? anchorPos + Date().timeIntervalSince(anchorDate) : anchorPos
    }

    func lineIndex(at t: Double) -> Int? {
        lines.lastIndex { $0.start <= t }
    }

    // MARK: Browser
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    // MARK: Session
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connected = (state == .connected)
            if state == .notConnected {
                // Look again so we reconnect when the Mac reappears.
                self.browser.stopBrowsingForPeers()
                self.browser.startBrowsingForPeers()
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        DispatchQueue.main.async {
            switch message {
            case let .lyrics(title, artist, lines):
                self.title = title
                self.artist = artist
                self.lines = lines
            case let .clock(isPlaying, position):
                self.isPlaying = isPlaying
                self.anchorPos = position
                self.anchorDate = Date()
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
