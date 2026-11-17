import Foundation
import MultipeerConnectivity

/// Advertises this Mac over the local network (Bonjour via MultipeerConnectivity)
/// and streams lyrics + playback clock to any Neko Lyrics iPhone viewer nearby.
/// Traffic is encrypted. Any device on your network running the viewer can join;
/// it only receives lyrics text and playback position.
final class PhoneSync: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    private let peer = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser

    /// Called on the main thread when a phone connects, so the caller can resend state.
    var onPeerConnected: (() -> Void)?

    override init() {
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "nekolyrics")
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    func start() { advertiser.startAdvertisingPeer() }

    func send(_ message: WireMessage) {
        guard !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: MCNearbyServiceAdvertiserDelegate
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    // MARK: MCSessionDelegate
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .connected {
            DispatchQueue.main.async { [weak self] in self?.onPeerConnected?() }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
