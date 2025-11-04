import Flutter
import UIKit
import NearbyInteraction
import MultipeerConnectivity
import os

// This extension of Error is required to do use FlutterError in any Swift code.
extension FlutterError: Error {}

public class UwbPlugin: NSObject, FlutterPlugin, UwbHostApi, NISessionDelegate {
    
    // Host > Flutter
    static var flutterApi: UwbFlutterApi? = nil
    
    // Event Channels Data Handler
    static var uwbDataHandler: UwbDataHandler? = nil
    static var debugLogHandler: FlutterEventSink? = nil
    
    private var appName: String? = nil
    private var serviceId: String? = nil
    private var identityId: String? = nil
    private var deviceName: String? = nil
    
    private var isDiscovering = false
    
    // Handles all NI Sessions
    private var niManager: NISessionManager = NISessionManager()
    
    // Bluetooth Accessory Discovery Service
    private var bluetoothManager = BluetoothManager()
    
    // iPhone to iPhone Discovery Service
    private var mpcManager: MultipeerConnectivityManager? = nil
    
    private let logger = os.Logger(subsystem: "uwb_plugin", category: "UwbPlugin")
    
    private var pendingInvitations : [String] = []
    
    override init() {
        super.init()
        self.bluetoothManager.accessoryDiscoveryHandler = accessoryFound
        self.bluetoothManager.accessoryConnectedHandler = accessoryConnected
        self.bluetoothManager.accessoryDisconnectedHandler = accessoryDisconnected
        self.bluetoothManager.accessoryDataHandler = accessorySharedData
        self.bluetoothManager.accessoryLostHandler = accessoryLost
        
        self.niManager.permissionRequiredHandler = uwbPermissionRequired
        self.niManager.uwbSessionStarted = uwbSessionStarted
        self.niManager.uwbSessionStopped = uwbPeerDisconnected
        self.niManager.accessorySharedConfig = accessorySharedConfig
        
        self.appName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String
    self.serviceId = "uwb-app-test-id"
    // Use a fixed identity to ensure MultipeerDiscoveryInfo matches across builds
    self.identityId = "uwb-identity" 
    }
    
    private func initMpcSession(deviceName: String, serviceId: String, identityId: String) {
        let validService = convertToValidServiceId(serviceId: serviceId)
        logger.log("Initializing MPC Session with service: \(validService), identity: \(identityId), peer: \(deviceName)")
        sendDebugLog("[MPC] Initializing MPC with service: \(validService) identity: \(identityId) peer: \(deviceName)")
        self.mpcManager = MultipeerConnectivityManager(
            localPeerId: deviceName,
            service: validService,
            identity: identityId
        )
        self.mpcManager?.peerConnectedHandler = mpcPeerConnected
        self.mpcManager?.dataReceivedHandler = mpcDataReceivedHandler
        self.mpcManager?.peerDisconnectedHandler = mpcPeerDisconnected
        self.mpcManager?.peerFoundHandler = mpcPeerFound
        self.mpcManager?.peerLostHandler = mpcPeerLost
        self.mpcManager?.peerInvitedHandler = mpcPeerInvited
        self.mpcManager?.debugLogHandler = sendDebugLog
    }
     
    private func sendDebugLog(_ message: String) {
        DispatchQueue.main.async {
            UwbPlugin.debugLogHandler?(message)
        }
    }

    // Send peer instead of uwb Device
    func accessoryFound(peer: Peer) {
        UwbPlugin.flutterApi?.onHostDiscoveryDeviceFound(
            device: UwbDevice(
                id: peer.id,
                name: peer.name,
                deviceType: DeviceType.accessory,
                state: DeviceState.found
            ),
            completion: {e in}
        )
    }
    
    // Callback Bluetooth Manager
    func accessoryLost(peer: Peer) {
        UwbPlugin.flutterApi?.onHostDiscoveryDeviceLost(
            device: UwbDevice(
                id: peer.id,
                name: peer.name,
                deviceType: DeviceType.accessory,
                state: DeviceState.lost
            ),
            completion: {e in}
        )
    }
    
    // Callback Bluetooth Manager
    func accessorySharedConfig(data: Data, peerId: String) {
        logger.log("Sent shareable configuration data to \(peerId)")
        do {
            try
            self.bluetoothManager.sendData(data: data, deviceId: peerId)
        } catch {
            logger.error("Failed to share accessory config.")
        }
    }
    
    // Callback Bluetooth Manager
    func accessoryConnected(peer: Peer) {
        UwbPlugin.flutterApi?.onHostDiscoveryDeviceConnected(
            device: UwbDevice(
                id: peer.id,
                name: peer.name,
                deviceType: DeviceType.smartphone,
                state: DeviceState.connected
            ),
            completion: {e in}
        )
        
        self.niManager.initAccessorySession(peer: peer)
        
        let msg = Data([MessageId.initialize.rawValue])
        do {
            try bluetoothManager.sendData(data: msg, deviceId: peer.id)
        } catch {
            logger.error("Failed to send data to accessory: \(error)")
        }
    }
    
    // Callback Bluetooth Manager
    func accessoryDisconnected(peer: Peer) {
        logger.log("Accessory Disconnected: \(peer.name)")
        UwbPlugin.flutterApi?.onHostDiscoveryDeviceDisconnected(
            device: UwbDevice(
                id: peer.id,
                name: peer.name,
                deviceType: DeviceType.accessory,
                state: DeviceState.disconnected
            ),
            completion: {e in}
        )
    }
    
    // Callback Bluetooth Manager
    private func accessorySharedData(data: Data, peer: Peer) {
        if data.count < 1 {
           return
        }
        
        // Assign the first byte which is the message identifier.
        guard let messageId = MessageId(rawValue: data.first!) else {
            fatalError("\(data.first!) is not a valid MessageId.")
        }
        
        switch messageId {
            case .accessoryConfigurationData:
                assert(data.count > 1)
                let message = data.advanced(by: 1)
                self.niManager.startSessionWithAccessory(
                    configData: message,
                    peer: peer
                )
            case .accessoryUwbDidStart:
            logger.log("UWB Session with accessory started.")
                UwbPlugin.flutterApi?.onHostUwbSessionStarted(
                    device: UwbDevice(
                        id: peer.id,
                        name: peer.name,
                        deviceType: DeviceType.accessory,
                        state: DeviceState.ranging
                    ),
                    completion: {e in}
                )
            case .accessoryUwbDidStop:
            logger.log("UWB Session with accessory stoped.")
            case .configureAndStart:
                fatalError("Accessory should not send 'configureAndStart'.")
            case .initialize:
                fatalError("Accessory should not send 'initialize'.")
            case .stop:
                NSLog("Stop.")
            case .getReserved:
                NSLog("Get not implemented in this version")
            case .setReserved:
                NSLog("Set not implemented in this version")
            case .iOSNotify:
                NSLog("Notification not implemented in this version")
        }
    }
    
    // Flutter API
    func discoverDevices(deviceName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        isDiscovering = true
        // TODO: assert device name
        
        // check if its a new name if so create a new mc session
        if (self.deviceName != deviceName || self.mpcManager == nil) {
            self.deviceName = deviceName
            
            // invalidate previous session
            self.mpcManager?.invalidate()
            
            initMpcSession(deviceName: deviceName, serviceId: self.serviceId!, identityId: self.identityId!)
        }
        
        self.mpcManager?.startAdvertising()
        self.mpcManager?.startDiscovery()
        self.bluetoothManager.start()
        completion(.success(()))
    }
    
    // Flutter API
    func stopDiscovery(completion: @escaping (Result<Void, Error>) -> Void) {
        self.isDiscovering = false
        self.mpcManager?.stopDiscovery()
        self.mpcManager?.stopAdvertising()
        self.bluetoothManager.stop()
        completion(.success(()))
    }
    
   // Flutter API
    func handleConnectionRequest(device: UwbDevice, accept: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try self.mpcManager?.handleInvitation(peerId: device.id, accept: accept)
        } catch let error  {
            completion(.failure(error))
        }
        completion(.success(()))
    }
    
    // Flutter API
    func startRanging(device: UwbDevice, completion: @escaping (Result<Void, Error>) -> Void) {
        if (device.deviceType == DeviceType.smartphone) {
            connectWithPhone(device: device)
        } else {
            connectWithAccessory(device: device)
        }
        
        completion(.success(()))
    }
    
    private func connectWithPhone(device: UwbDevice) {
        if !pendingInvitations.contains(device.id) {
            self.pendingInvitations.append(device.id)
        }
        self.mpcManager?.invitePeer(peerId: device.id)
    }
    
    private func connectWithAccessory(device: UwbDevice) {
        do {
            try bluetoothManager.connectPeripheral(deviceId: device.id)
        } catch {
            logger.error("Failed to connect to accessory: \(error)")
        }
    }
    
    // Flutter API
    func stopRanging(device: UwbDevice, completion: @escaping (Result<Void, Error>) -> Void) {
        if (device.deviceType == DeviceType.smartphone) {
            self.mpcManager?.disconnectFromPeer(peerId: device.id)
        } else {
            self.bluetoothManager.disconnectPeripheral(deviceId: device.id)
            do {
                try self.bluetoothManager.sendData(data: Data([MessageId.stop.rawValue]), deviceId: device.id)
                try self.bluetoothManager.sendData(data: Data([MessageId.initialize.rawValue]), deviceId: device.id)
            } catch {
                logger.error("Failed to send data to accessory: \(error)")
            }
        }
        self.niManager.stopSession(peerId: device.id)
        completion(.success(()))
    }
    
    // Flutter API
    func stopUwbSessions(completion: @escaping (Result<Void, Error>) -> Void) {
        self.niManager.stopSessions()
        completion(.success(()))
    }
       
    // Flutter API
    func isUwbSupported(completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(NISession.isSupported))
    }

    // NI Session Manager delegate
    func uwbPermissionRequired(action: PermissionAction) {
        UwbPlugin.flutterApi?.onHostPermissionRequired(
            action: action,
            completion: {e in}
        )
    }
    
    // NI Session Manager delegate
    func uwbSessionStarted(peerId: String) {
        DispatchQueue.main.async {
            UwbPlugin.flutterApi?.onHostUwbSessionStarted(
                device: UwbDevice(
                    id: peerId,
                    name: peerId,
                    deviceType: DeviceType.smartphone,
                    state: DeviceState.ranging
                ),
                completion: {e in}
            )
        }

    }
    
    // MultipeerConnectivity delegate
    private func uwbPeerDisconnected(peerId: String, type: DeviceType) {
        
        if (type == DeviceType.accessory) {
            do {
                try self.bluetoothManager.sendData(data: Data([MessageId.stop.rawValue]), deviceId: peerId)
                try self.bluetoothManager.sendData(data: Data([MessageId.initialize.rawValue]), deviceId: peerId)
                self.bluetoothManager.disconnectPeripheral(deviceId: peerId)
            } catch {
                logger.error("Failed to send data to accessory: \(error)")
            }
        }
        
        DispatchQueue.main.async {
            UwbPlugin.flutterApi?.onHostUwbSessionDisconnected(
                device: UwbDevice(
                    id: peerId,
                    name: peerId,
                    deviceType: type,
                    state: DeviceState.disconnected
                ),
                completion: {e in}
            )
        }
    }
    
    private func convertToValidServiceId(serviceId: String) -> String {
        // cap string to max 15 characters
        let cappedServiceId = String(serviceId.prefix(15))

        // remove underscores or dashes
        let validServiceId = cappedServiceId.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        
        return validServiceId
    }

    // MultipeerConnectivity delegate
    private func mpcPeerFound(peerId: String) {
        DispatchQueue.main.async {
            UwbPlugin.flutterApi?.onHostDiscoveryDeviceFound(
                device:  UwbDevice(
                    id: peerId,
                    name: peerId,
                    deviceType: DeviceType.smartphone,
                    state: DeviceState.found
                ),
                completion: {e in}
            )
        }
    }
    
    private func mpcPeerInvited(peerId: String) {
        DispatchQueue.main.async {
            UwbPlugin.flutterApi?.onHostDiscoveryConnectionRequestReceived(
                device: UwbDevice(
                    id: peerId,
                    name: peerId,
                    deviceType: DeviceType.smartphone,
                    state: DeviceState.pending
                ),
                completion: {e in}
            )
        }
    }
       
    // MultipeerConnectivity delegate
    private func mpcPeerLost(peerId: String) {
        DispatchQueue.main.async {
            UwbPlugin.flutterApi?.onHostDiscoveryDeviceLost(
                device: UwbDevice(
                    id: peerId,
                    name: peerId,
                    deviceType: DeviceType.smartphone,
                    state: DeviceState.lost
                ),
                completion: {e in}
            )
        }
    }
   
    // MultipeerConnectivity delegate
    private func mpcPeerConnected(peerId: String) {
        guard let myToken = self.niManager.initPhoneSession(
            peer: Peer(id: peerId, name: peerId)
        ) else {
            logger.error("Can't init Phone session \(peerId).")
            return
        }
        
        // remove from list
        if let index = pendingInvitations.firstIndex(of: peerId) {
            pendingInvitations.remove(at: index)
        }
        self.shareDiscoveryTokenWithPhone(peerId: peerId, token: myToken)
        
        DispatchQueue.main.async {
            UwbPlugin.flutterApi?.onHostDiscoveryDeviceConnected(
                device: UwbDevice(
                    id: peerId,
                    name: peerId,
                    deviceType: DeviceType.smartphone,
                    state: DeviceState.connected
                ),
                completion: {e in}
            )
        }
    }
   
    // MultipeerConnectivity delegate
    private func mpcPeerDisconnected(peerId: String) {
        // There is no rejected event by MPC, so check if we have some pending invations
        if let index = pendingInvitations.firstIndex(of: peerId) {
            pendingInvitations.remove(at: index)
            
            DispatchQueue.main.async {
                UwbPlugin.flutterApi?.onHostDiscoveryDeviceRejected(
                    device: UwbDevice(
                        id: peerId,
                        name: peerId,
                        deviceType: DeviceType.smartphone,
                        state: DeviceState.rejected
                    ),
                    completion: {e in}
                )
            }
        } else {
            // Force to stop UWB Session, so we don't have to wait for UWB Timeout.
            if (self.niManager.isDeviceRanging(deviceId: peerId)) {
                self.niManager.stopSession(peerId: peerId)
                self.uwbPeerDisconnected(peerId: peerId, type: DeviceType.smartphone)
                if (isDiscovering) {
                    self.mpcManager?.restartDiscovery()
                }
            }
            
            DispatchQueue.main.async {
                UwbPlugin.flutterApi?.onHostDiscoveryDeviceDisconnected(
                    device: UwbDevice(
                        id: peerId,
                        name: peerId,
                        deviceType: DeviceType.smartphone,
                        state: DeviceState.disconnected
                    ),
                    completion: {e in}
                )
            }
        }
    }

    // MultipeerConnectivity
    private func mpcDataReceivedHandler(data: Data, peerId: String) {
        logger.log("Data Received from: \(peerId)")
        guard let discoveryToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
            fatalError("Unexpectedly failed to decode discovery token.")
        }

        self.niManager.startSessionWithPhone(peerId: peerId, peerDiscoveryToken: discoveryToken)
        logger.log("Start Session with \(peerId)")
    }
    
    private func shareDiscoveryTokenWithPhone(peerId: String, token: NIDiscoveryToken) {
        guard let encodedData = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            fatalError("Unexpectedly failed to encode discovery token.")
        }
        self.mpcManager?.sendDataToPeer(data: encodedData, peerId: peerId)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger : FlutterBinaryMessenger = registrar.messenger()
    // Create plugin instance and expose it both as the Pigeon host API and as a
    // FlutterPlugin (for method channel delegate registration).
    let plugin = UwbPlugin.init()
    let api: UwbHostApi & NSObjectProtocol = plugin
    UwbHostApiSetup.setUp(binaryMessenger: messenger, api: api)
        
        // Initialize all event channels
        let uwbDataChannel = FlutterEventChannel(name: "uwb_plugin/uwbData", binaryMessenger: messenger)
        uwbDataHandler = UwbDataHandler()
        uwbDataChannel.setStreamHandler(uwbDataHandler)
        
        let debugLogChannel = FlutterEventChannel(name: "uwb_plugin/debug_logs", binaryMessenger: messenger)
        let debugStreamHandler = DebugLogStreamHandler()
        debugLogChannel.setStreamHandler(debugStreamHandler)
        
        // Diagnostics method channel: allow Flutter to request native health dumps
        let diagChannel = FlutterMethodChannel(name: "uwb_plugin/diagnostics", binaryMessenger: messenger)
        // registrar expects a FlutterPlugin; pass the plugin instance we created above.
        registrar.addMethodCallDelegate(plugin, channel: diagChannel)
        
        flutterApi = UwbFlutterApi(binaryMessenger: messenger)
    }
}

// Handle diagnostics method calls
extension UwbPlugin {
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "dumpMpcHealth" {
            if let dump = self.mpcManager?.healthDump() {
                // Send via debug log stream so Flutter UI can display and copy it
                sendDebugLog("[MPC] Health Dump: \(dump)")
                result(nil)
                return
            } else {
                sendDebugLog("[MPC] Health Dump: mpcManager not initialized")
                result(nil)
                return
            }
        }
        result(FlutterMethodNotImplemented)
    }
}

class DebugLogStreamHandler: NSObject, FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        UwbPlugin.debugLogHandler = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        UwbPlugin.debugLogHandler = nil
        return nil
    }
}
