/*
Copyright © 2022 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Abstract:
A class that manages peer discovery-token exchange over the local network by using MultipeerConnectivity.

Modified by Christian Greiner
*/

import Flutter
import Foundation
import MultipeerConnectivity
import os

struct MPCSessionConstants {
    static let kKeyIdentity: String = "identity"
}

class MultipeerConnectivityManager: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    
    // Handlers
    var dataReceivedHandler: ((Data, String) -> Void)?
    var peerConnectedHandler: ((String) -> Void)?
    var peerDisconnectedHandler: ((String) -> Void)?
    var peerFoundHandler: ((_: String) -> Void)?
    var peerLostHandler: ((String) -> Void)?
    var peerInvitedHandler: ((String) -> Void)?
    var debugLogHandler: ((String) -> Void)?
    
    private let mcSession: MCSession
    private let mcAdvertiser: MCNearbyServiceAdvertiser
    private let mcBrowser: MCNearbyServiceBrowser
    
    private let identityString: String
    private var nearbyPeers: [String: MCPeerID] = [:]
    private var localMCPeer: MCPeerID
    private var localPeerId: String
    private let logger = os.Logger(subsystem: "uwb_plugin", category: "MultipeerConnectivityManager")

    private var invitations: [String: ((Bool, MCSession?) -> Void)?] = [:]
    // Track advertiser/browser state for diagnostics
    private var isAdvertising: Bool = false
    private var isBrowsing: Bool = false
    
    init(localPeerId: String, service: String, identity: String) {
        self.localPeerId = localPeerId
        self.localMCPeer = MCPeerID(displayName: localPeerId)
        self.identityString = identity
        self.mcSession = MCSession(peer: localMCPeer, securityIdentity: nil, encryptionPreference: .optional)
        
        // Init Adveritiser
        self.mcAdvertiser = MCNearbyServiceAdvertiser(
            peer: localMCPeer,
            discoveryInfo: [
                MPCSessionConstants.kKeyIdentity: identityString
            ],
            serviceType: service
        )
        
        // Init Discovery
        self.mcBrowser = MCNearbyServiceBrowser(peer: localMCPeer, serviceType: service)
        
        super.init()
        
        mcSession.delegate = self
        mcAdvertiser.delegate = self
        mcBrowser.delegate = self
    }
    
    // MARK: - `MPCSession` public methods.
    func startAdvertising() {
        mcAdvertiser.startAdvertisingPeer()
        logger.log("Advertising started.")
        isAdvertising = true
        debugLogHandler?("[MPC] Advertising started.")
        // Log the raw discoveryInfo we are advertising so Flutter can display it
        let advInfo = [MPCSessionConstants.kKeyIdentity: identityString]
        debugLogHandler?("[MPC] Advertising discoveryInfo: \(advInfo)")
    }
    
    func stopAdvertising() {
        mcAdvertiser.stopAdvertisingPeer()
        logger.log("Advertising stoped.")
        isAdvertising = false
        debugLogHandler?("[MPC] Advertising stopped.")
    }
    
    func startDiscovery() {
        nearbyPeers = [:]
        mcBrowser.startBrowsingForPeers()
        logger.log("Discovery started.")
        isBrowsing = true
        debugLogHandler?("[MPC] Discovery started.")
    }
    
    func stopDiscovery() {
        nearbyPeers = [:]
        mcBrowser.stopBrowsingForPeers()
        logger.log("Discovery stoped.")
        isBrowsing = false
        debugLogHandler?("[MPC] Discovery stopped.")
    }
    
    func invalidate() {
        stopDiscovery()
        stopAdvertising()
        mcSession.disconnect()
        self.invitations.removeAll()
        debugLogHandler?("[MPC] Session invalidated.")
    }
    
    func restartDiscovery() {
        stopDiscovery()
        stopAdvertising()
        startDiscovery()
        startAdvertising()
        debugLogHandler?("[MPC] Discovery restarted.")
    }
    
    func disconnectFromPeer(peerId: String) {
        if nearbyPeers[peerId] == nil {
            logger.warning("Peer \(peerId) not found. Disconnect failed.")
            debugLogHandler?("[MPC] Peer \(peerId) not found for disconnect.")
            return
        }
        mcSession.cancelConnectPeer(nearbyPeers[peerId]!)
        debugLogHandler?("[MPC] Disconnecting from peer \(peerId).")
    }
    
    func sendDataToPeer(data: Data, peerId: String) {
        do {
            NSLog("Send Data to peer: \(peerId)")
            logger.log("Send Data to Peer: \(peerId)")
            debugLogHandler?("[MPC] Sending data to peer: \(peerId)")
            let peer = mcSession.connectedPeers.first { (peerObj) -> Bool in
                return peerObj.displayName == peerId
            }
        
            if (peer == nil) {
                // TODO Exception handling
                logger.error("Couldn't find Peer: \(peerId). Failed sending data.")
                debugLogHandler?("[MPC] Peer \(peerId) not found for sending data.")
            }
            
            try mcSession.send(data, toPeers: [peer!], with: .reliable)
            
        } catch let error {
            logger.error("Failed sending data: \(error)")
            debugLogHandler?("[MPC] Error sending data: \(error.localizedDescription)")
        }
    }

    func sendData(data: Data, peers: [MCPeerID], mode: MCSessionSendDataMode) {
        do {
            try mcSession.send(data, toPeers: peers, with: mode)
        } catch let error {
            logger.error("Failed sending data: \(error)")
        }
    }

    public func invitePeer(peerId: String) {
        logger.log("Invite Peer \(peerId) to session.")
        debugLogHandler?("[MPC] Inviting peer \(peerId).")
        guard let peer = nearbyPeers[peerId] else {
            logger.warning("Peer \(peerId) not found. Can't invite peer.")
            debugLogHandler?("[MPC] Peer \(peerId) not found for invitation.")
            return
        }
        mcBrowser.invitePeer(peer, to: mcSession, withContext: nil, timeout: 10)
    }
    
    public func handleInvitation(peerId: String, accept: Bool) throws {
        if let handler = invitations[peerId] {
            logger.log("Peer \(peerId) accepted inivation?: \(accept)")
            debugLogHandler?("[MPC] Handling invitation from \(peerId). Accepted: \(accept)")
            handler!(accept, self.mcSession)
        } else {
            // TODO: Throw exceptions
            throw FlutterError(
                code: "\(ErrorCode.oOBCONNECTIONERROR.rawValue)",
                message: "Handler not found.",
                details: nil
            )
        }
    }
    
    // MARK: - `MPCSession` private methods.
    private func peerConnected(peerID: MCPeerID) {
        logger.log("Peer \(peerID.displayName) connected.")
        debugLogHandler?("[MPC] Peer connected: \(peerID.displayName)")
        if let handler = peerConnectedHandler {
            handler(peerID.displayName)
        }
    }

    private func peerDisconnected(peerID: MCPeerID) {
        logger.log("Peer \(peerID.displayName) disconnected.")
        debugLogHandler?("[MPC] Peer disconnected: \(peerID.displayName)")
        if let handler = peerDisconnectedHandler {
            handler(peerID.displayName)
        }
    }

    // MARK: - `MCSessionDelegate`.
    // Remote peer changed state.
    internal func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
            case .connected:
                peerConnected(peerID: peerID)
            case .notConnected:
                peerDisconnected(peerID: peerID)
            case .connecting:
                debugLogHandler?("[MPC] Peer connecting: \(peerID.displayName)")
                break
            @unknown default:
                fatalError("Unhandled MCSessionState")
        }
    }

    // Received data from remote peer.
    internal func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        logger.log("Peer \(peerID.displayName) sent data.")
        debugLogHandler?("[MPC] Received data from \(peerID.displayName).")
        if let handler = dataReceivedHandler {
            handler(data, peerID.displayName)
        }
    }

    // Received a byte stream from remote peer.
    internal func session(_ session: MCSession,
                            didReceive stream: InputStream,
                            withName streamName: String,
                            fromPeer peerID: MCPeerID) {
    }
    
    // Start receiving a resource from remote peer.
    internal func session(_ session: MCSession,
                          didStartReceivingResourceWithName resourceName: String,
                          fromPeer peerID: MCPeerID,
                          with progress: Progress) {
    }

    // Finished receiving a resource from remote peer and saved the content
    // in a temporary location - the app is responsible for moving the file
    // to a permanent location within its sandbox.
    internal func session(_ session: MCSession,
                          didFinishReceivingResourceWithName resourceName: String,
                          fromPeer peerID: MCPeerID,
                          at localURL: URL?,
                          withError error: Error?) {
    }

    // MARK: - `MCNearbyServiceBrowserDelegate`.
    // Found a nearby advertising peer.
    internal func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Log the raw discoveryInfo received from the peer for debugging
        debugLogHandler?("[MPC] Raw discoveryInfo from \(peerID.displayName): \(String(describing: info))")

        // The discovery info contains the identity of the peer, which is used to identify the app.
        // We are looking for peers with the same identity.
        guard let info = info, let identityValue = info[MPCSessionConstants.kKeyIdentity], identityValue == identityString else {
            debugLogHandler?("[MPC] Ignored peer with mismatched identity or no info: \(peerID.displayName)")
            return
        }

        // Don't hang onto a peer that's already been connected.
        if mcSession.connectedPeers.contains(peerID) {
            debugLogHandler?("[MPC] Ignored already-connected peer \(peerID.displayName)")
            return
        }
        
        // Do not connect to self
        if peerID == localMCPeer {
            debugLogHandler?("[MPC] Ignored self: \(peerID.displayName)")
            return
        }

        logger.log("Discovered Peer \(peerID.displayName) found.")
        debugLogHandler?("[MPC] Found peer: \(peerID.displayName). Identity: \(identityValue)")
        nearbyPeers[peerID.displayName] = peerID
        if let handler = peerFoundHandler {
            handler(peerID.displayName)
        }
    }

    // Returns a diagnostic summary of current MPC internals
    func healthDump() -> String {
        var parts: [String] = []
        parts.append("advertising: \(isAdvertising)")
        parts.append("browsing: \(isBrowsing)")
        let connected = mcSession.connectedPeers.map { $0.displayName }
        parts.append("connectedPeers: \(connected)")
        let nearby = Array(nearbyPeers.keys)
        parts.append("nearbyPeers: \(nearby)")
        parts.append("invitations: \(Array(invitations.keys))")
        return parts.joined(separator: " | ")
    }
    
    // A nearby peer has stopped advertising.
    internal func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        logger.log("Peer \(peerID.displayName) lost.")
        debugLogHandler?("[MPC] Lost peer: \(peerID.displayName).")
        nearbyPeers.removeValue(forKey: peerID.displayName)
        if let handler = peerLostHandler {
            handler(peerID.displayName)
        }
    }

    // MARK: - `MCNearbyServiceAdvertiserDelegate`.
    // Incoming invitation request. Call the invitationHandler block with YES
    // and a valid session to connect the inviting peer to the session.
    internal func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                             didReceiveInvitationFromPeer peerID: MCPeerID,
                             withContext context: Data?,
                             invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        
        logger.log("Incoming inivation request by \(peerID.displayName).")
        debugLogHandler?("[MPC] Received invitation from \(peerID.displayName).")
        
        self.invitations[peerID.displayName] = invitationHandler
        
        if let handler = peerInvitedHandler {
            handler(peerID.displayName)
        }
    }
}
