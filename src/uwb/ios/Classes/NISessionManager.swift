import Foundation
import NearbyInteraction
import MultipeerConnectivity
import os

class NISessionManager: NSObject, NISessionDelegate {
        
    var uwbSessionStarted: ((String) -> Void)?
    var uwbSessionStopped: ((String, DeviceType) -> Void)?
    var permissionRequiredHandler: ((PermissionAction) -> Void)?
    
    var accessorySharedConfig: ((Data, String) -> Void)?
    
    // Mas peerId to NIPeer
    private var sessions = [String: NIPeer]()
    
    private var prevDistance: Float? = nil
    private var prevDirection: simd_float3? = nil
    private var prevHorizontalAngle: Float? = nil
    
    private let logger = os.Logger(subsystem: "uwb_plugin", category: "NISessionManager")
  
    public func isDeviceRanging(deviceId: String) -> Bool {
        return sessions.keys.contains(deviceId)
    }
    
    public func invalidateSessions() {
        for niPeer in sessions.values {
            niPeer.session.invalidate()
        }
    }
    
    public func initPhoneSession(peer: Peer) -> NIDiscoveryToken? {
        let peerSession = NISession()
        peerSession.delegate = self
        
        guard let myToken = peerSession.discoveryToken else {
            logger.error("Session is invalid. Can't access discovery token.")
            return nil
        }
        
        logger.log("Init NI Session with Peer: \(peer.id)")
        
        sessions[peer.id] = NIPeer(
            peer: peer,
            session: peerSession,
            peerType: DeviceType.smartphone
        )
        return myToken
    }
    
    public func initAccessorySession(peer: Peer) {
        if sessions.keys.contains(peer.id) {
            NSLog("Peer \(peer.id) already initialized.")
            return
        }
        
        let accessorySession = NISession()
        accessorySession.delegate = self
        
        logger.log("Init NI Session with Accessory: \(peer.id)")
        sessions[peer.id] = NIPeer(
            peer: peer,
            session: accessorySession,
            peerType: DeviceType.accessory
        )
    }
    
    // MARK: - Accessory messages handling
    public func startSessionWithAccessory(configData: Data, peer: Peer) {
        if #available(iOS 15.0, *) {
            do {
                let configuration = try NINearbyAccessoryConfiguration(data: configData)

                // TODO: Check if this works with multiple devices
                // this works only with on peer
                if #available(iOS 16.0, *) {
                    //configuration.isCameraAssistanceEnabled = true
                }

                logger.log("Accessory Session with \(peer.id) configured and stared.")
                logger.log("Accessory Token: \(configuration.accessoryDiscoveryToken)")
                sessions[peer.id]!.peerDiscoveryToken = configuration.accessoryDiscoveryToken
                sessions[peer.id]!.session.run(configuration)
                logger.log("Run Session with \(peer.id).")

                if let handler = uwbSessionStarted {
                    handler(peer.id)
                }
            }
            catch {
                logger.error("Accessory Configuration failed. Invalid Conig data.")
                return
            }
        } else {
            // NINearbyAccessoryConfiguration is only available on iOS 15+. On older OS versions
            // we can't configure accessory-based NearbyInteraction sessions. Log and return.
            logger.error("NINearbyAccessoryConfiguration requires iOS 15.0+. Accessory sessions are not supported on this OS.")
            return
        }
    }
    
    public func stopSession(peerId: String) {
        if !sessions.keys.contains(peerId) {
            logger.error("Peer \(peerId) doesn't exists.")
            return
        }
        
        self.sessions[peerId]?.session.invalidate()
        self.sessions.removeValue(forKey: peerId)
    }
    
    public func stopSessions() {
        for niPeer in sessions.values {
            niPeer.session.invalidate()
            sessions.removeValue(forKey: niPeer.peer.id)
        }
    }
    
    // Nach erhalt des Tokens von einem iPhone
    public func startSessionWithPhone(peerId: String, peerDiscoveryToken: NIDiscoveryToken) {
        guard sessions[peerId] != nil else {
            logger.error("Session with \(peerId) doesn't exists.")
            return
        }
        
        sessions[peerId]?.peerDiscoveryToken = peerDiscoveryToken
        
        let config = NINearbyPeerConfiguration(peerToken: peerDiscoveryToken)
        if #available(iOS 16.0, *) {
            config.isCameraAssistanceEnabled = true
        }
        
        logger.log("Start NISession with \(peerId).")
        
        // Run the session.
        sessions[peerId]!.session.run(config)
        
        if let handler = uwbSessionStarted {
            handler(peerId)
        }
    }
    
    /**
    Provides configuration data that needs to be shared with the accessory.
    @note Shareable configuration data is only provided when running an NINearbyAccessoryConfiguration.
    @discussion After invoking this callback, the session will go into a special preparedness state for a limited amount of time.
    The interaction on the accessory must start within this time window. If activity is not detected from the accessory, the session will call
    the -[session:didRemoveNearbyObjects:reason:] delegate callback. To restart the session, coordinate with the accessory and call -[runWithConfiguration] again.
     
    @param session The session which produced the configuration data.
    @param shareableConfigurationData The configuration data that needs to be shared with the accessory.
    @param object A representation of the accessory as a NINearbyObject. The discoveryToken property will be equal to the one in the configuration used to run the session.
    */
    func session(_ session: NISession, didGenerateShareableConfigurationData shareableConfigurationData: Data, for object: NINearbyObject) {
        let niPeer = getNIPeerByDiscoveryToken(session: session)
        guard object.discoveryToken == niPeer?.peerDiscoveryToken else {
            logger.error("Discovery Token is not equal with the peer and nearby Object")
            return
        }
        
        // Prepare to send a message to the accessory.
        var msg = Data([MessageId.configureAndStart.rawValue])
        msg.append(shareableConfigurationData)
        
        let str = msg.map { String(format: "0x%02x, ", $0) }.joined()
        logger.log("Sending shareable configuration bytes: \(str)")
                        
        if let handler = accessorySharedConfig {
            handler(msg, niPeer!.peer.id)
        }
    }
      
    /**
     This is called when new updates about nearby objects are available.
     @param session The nearby interaction session being run.
     @param nearbyObjects The nearby objects that have been updated.
    */
    internal func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let nearbyObject = nearbyObjects.first else { return }
        guard let niPeer = getNIPeerByDiscoveryToken(session: session) else {
            return
        }
        
        // Only update if distance is nil
        if nearbyObject.distance == nil {
            return
        }
        
        var horizontalAngle: Float?
        if #available(iOS 16.0, *) {
            horizontalAngle = nearbyObject.horizontalAngle
        }
        
        var azimuth: Float = 0.0
        var elevation: Float = 0.0
        if (nearbyObject.direction != nil) {
            azimuth = asin(nearbyObject.direction!.x)
            elevation = atan2(nearbyObject.direction!.z, nearbyObject.direction!.y) + .pi / 2
        }

        // Stream RAW data
        UwbPlugin.uwbDataHandler?.sendData(
            peerId: niPeer.peer.id,
            name: niPeer.peer.name,
            distance: nearbyObject.distance,
            direction: nearbyObject.direction,
            horizontalAngle: horizontalAngle,
            azimuth: 90 * azimuth,
            elevation: 90 * elevation,
            deviceType: niPeer.peerType
        )
    }
    
    private func getNINearbyObjectByToken(nearbyObjects: [NINearbyObject]) -> NINearbyObject? {
        let peerObj = nearbyObjects.first { (obj) -> Bool in
            return sessions.values.contains { (niPeer) -> Bool in
                return niPeer.peerDiscoveryToken == obj.discoveryToken
            }
        }
        return peerObj
    }
    
    private func getNIPeerByDiscoveryToken(session: NISession) -> NIPeer? {
        let niPeer = sessions.values.first(where: { (niPeer) -> Bool in
            return niPeer.session.discoveryToken == session.discoveryToken
        })
        return niPeer
    }

    // NISessionDelegate:  This is called when the system is no longer attempting to interact with some nearby objects.
    internal func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        
        // Retry the session only if the peer timed out.
        guard reason == .timeout else { return }
        logger.info("Session timed out.")

        guard let niPeer = getNIPeerByDiscoveryToken(session: session) else {
            return
        }
        
        self.sessions[niPeer.peer.id]?.session.invalidate()
        self.sessions.removeValue(forKey: niPeer.peer.id)
        
        if let handler = uwbSessionStopped {
            handler(niPeer.peer.id, niPeer.peerType)
        }
                
        switch reason {
            case .peerEnded:
                NSLog("UWB Peer Ended: \(niPeer.peer.id)")
            case .timeout:
                NSLog("UWB Peer Timeout: \(niPeer.peer.id)")
            default:
                fatalError("Unknown and unhandled NINearbyObject.RemovalReason")
        }
    }
    
    /**
     This is called when a session is suspended.
     @discussion A session will be suspended in various app and system scenarios.
     A suspended session may be run again only after -sessionSuspensionEnded: has been called.  Restart a session by issuing a new call to -runWithConfiguration:.
     @param session The nearby interaction session that was suspended.
    */
    internal func sessionWasSuspended(_ session: NISession) {
        // TODO: notify ui about unkown state
        
        let niPeer = getNIPeerByDiscoveryToken(session: session)
        logger.warning("Session is suspended: \(niPeer!.peer.id)")
        
        // Notify Accessory
    }

    /**
     This is called when a session may be resumed.
     @param session The nearby interaction session that was suspended.
    */
    internal func sessionSuspensionEnded(_ session: NISession) {
        // Session suspension ended. The session can now be run again.
        
        // TODO: Deal with Accessory and Iphone
       
        let niPeer = getNIPeerByDiscoveryToken(session: session)
                
        logger.log("Session suspended ended: \(niPeer!.peer.id)")

        if niPeer == nil {
            return
        }
        
        logger.log("Try to rerun the session with peer: \(niPeer!.peer.id)")
        if let config = niPeer?.session.configuration {
            logger.log("Rerun session with peer: \(niPeer!.peer.id)")
            session.run(config)
        } else {
            logger.warning("Needs to init a new session with Peer: \(niPeer!.peer.id)")
        }
        /*
            else {
            let newToken = initSession(niPeer!.peer)
            startSession(peerId: niPeer!.peerId, peerDiscoveryToken: newToken!)
        }*/
    }
    
    /**
     This is called when a session is invalidated.
     @param session The session that has become invalid. Your app should discard any references it has to this session.
     @param error The error indicating the reason for invalidation of the session (see NIError.h).
    */
    internal func session(_ session: NISession, didInvalidateWith error: Error) {
        // TODO: Notify Flutter UI about unkown state
        logger.warning("Session is invalidated. Reason: \(error.localizedDescription)")
        
        if case NIError.userDidNotAllow = error {
            if #available(iOS 15.0, *) {
                if let handler = permissionRequiredHandler {
                    handler(PermissionAction.request)
                }
            }
            return
        }
        
        if case NIError.activeSessionsLimitExceeded = error {
            // TODO: Notify about max sessions exceeded
        }
        
        // Remove invalid session
        let niPeer = getNIPeerByDiscoveryToken(session: session)
        
        if niPeer == nil {
            return
        }
        
        self.sessions[niPeer!.peer.id]?.session.invalidate()
        self.sessions.removeValue(forKey: niPeer!.peer.id)
    }
    
    func sessionDidStartRunning(_ session: NISession) {}
}
