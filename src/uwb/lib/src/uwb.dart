import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:uwb/flutter_uwb.dart';
import 'package:uwb/src/uwb_platform_interface.dart';

// UWB Instance for Plugin
class Uwb extends UwbPlatform {
  /// Returns a list of all discovered devices
  /// This list is updated whenever a new device is discovered, lost, connected
  /// or disconnected.
  Stream<Iterable<UwbDevice>> get discoveredDevicesStream => _discoveredDevicesStream.stream.asBroadcastStream();

  /// Notifies about the current state of the discovery process
  Stream<DiscoveryDeviceState> get discoveryStateStream => _discoveryStateStream.stream.asBroadcastStream();

  Stream<Iterable<UwbDevice>> get rangingDevicesStream => _rangingDevicesStream.stream.asBroadcastStream();

  Stream<UwbSessionState> get uwbSessionStateStream => _uwbSessionStateStream.stream.asBroadcastStream();

  /// Returns a list of all current ranging devices
  Stream<Iterable<UwbDevice>> get uwbDataStream {
    return _uwbDataChannel.receiveBroadcastStream().map(
      (data) {
        var device = _parseUwbData(data);
        _rangingDevices[device.id] = device;
        return _rangingDevices.values.toList();
      },
    ).asBroadcastStream();
  }

  final _discoveryStateStream = StreamController<DiscoveryDeviceState>.broadcast();
  final _discoveredDevicesStream = StreamController<Iterable<UwbDevice>>.broadcast();

  final _uwbSessionStateStream = StreamController<UwbSessionState>.broadcast();
  final _rangingDevicesStream = StreamController<Iterable<UwbDevice>>.broadcast();

  final _rangingDevices = <String, UwbDevice>{};
  final _discoveredDevices = <String, UwbDevice>{};

  // Stream Channels Setup
  final UwbHostApi _hostApi = UwbHostApi();
  final EventChannel _uwbDataChannel = const EventChannel('uwb_plugin/uwbData');
  late UwbFlutterApiHandler _flutterApiHandler;

  Uwb() {
    // Setup UWB API Handler
    _flutterApiHandler = UwbFlutterApiHandler(
      onDiscoveryDeviceFound: _onDiscoveryDeviceFound,
      onDiscoveryDeviceLost: _onDiscoveryDeviceLost,
      onDiscoveryDeviceConnected: _onDiscoveryDeviceConnected,
      onDiscoveryDeviceDisconnected: _onDiscoveryDeviceDisconnected,
      onDiscoveryDeviceRejected: _onDiscoveryDeviceRejected,
      onDiscoveryConnectionRequestReceived: _onDiscoveryConnectionRequestReceived,
      onPermissionRequired: _onPermissionRequired,
      onUwbSessionStarted: _onUwbSessionStarted,
      onUwbSessionDisconnected: _onUwbSessionDisconnected,
    );

    UwbFlutterApi.setup(_flutterApiHandler);
  }

  int maxConnections = -1;

  void _onDiscoveryDeviceFound(UwbDevice device) {
    if (!_discoveredDevices.containsKey(device.id)) {
      _discoveredDevices[device.id] = device;
      _discoveredDevicesStream.add(_discoveredDevices.values);

      _discoveryStateStream.add(
        DeviceFoundState(device),
      );
    }
  }

  void _onDiscoveryDeviceLost(UwbDevice device) {
    _discoveredDevices.remove(device.id);
    _discoveredDevicesStream.add(_discoveredDevices.values);

    _discoveryStateStream.add(
      DeviceLostState(device),
    );
  }

  void _onDiscoveryDeviceConnected(UwbDevice device) {
    if (_discoveredDevices.containsKey(device.id)) {
      _discoveredDevices[device.id] = device;
      _discoveredDevicesStream.add(_discoveredDevices.values);
    }

    _discoveryStateStream.add(
      DeviceConnectedState(device),
    );
  }

  void _onDiscoveryDeviceDisconnected(UwbDevice device) {
    if (_discoveredDevices.containsKey(device.id)) {
      _discoveredDevices[device.id] = device;
      _discoveredDevicesStream.add(_discoveredDevices.values);
    }

    _discoveryStateStream.add(
      DeviceDisconnectedState(device),
    );
  }

  void _onDiscoveryDeviceRejected(UwbDevice device) {
    _discoveryStateStream.add(DeviceInviteRejected(device));
  }

  void _onDiscoveryConnectionRequestReceived(UwbDevice device) {
    _discoveryStateStream.add(DeviceInvitedState(device));
  }

  void _onPermissionRequired(PermissionAction action) {}

  void _onUwbSessionStarted(UwbDevice device) {
    _rangingDevices[device.id] = device;
    _rangingDevicesStream.add(_rangingDevices.values);

    // Update the discovered devices list if still connected
    if (_discoveredDevices.containsKey(device.id)) {
      _discoveredDevices[device.id] = device;
      _discoveredDevicesStream.add(_discoveredDevices.values);
    }

    _uwbSessionStateStream.add(
      UwbSessionStartedState(device),
    );
  }

  void _onUwbSessionDisconnected(UwbDevice device) {
    // TODO: Check if device is still connected via OOB
    _discoveredDevices[device.id] = device;
    _discoveredDevicesStream.add(_discoveredDevices.values);

    _rangingDevices.remove(device.id);
    _rangingDevicesStream.add(_rangingDevices.values);

    _uwbSessionStateStream.add(
      UwbSessionDisconnectedState(device),
    );
  }

  /// Discover nearby devices
  /// [displayName] is the name of the device that will be shown to other devices
  @override
  Future<void> discoverDevices(String deviceName) async {
    try {
      return await _hostApi.discoverDevices(deviceName);
    } on PlatformException catch (e) {
      _parsePlatformException(e);
    }
  }

  @override
  Future<void> stopDiscovery() async {
    _discoveredDevices.removeWhere((key, value) => value.state != DeviceState.connected);
    _discoveredDevicesStream.add(_discoveredDevices.values);
    return await _hostApi.stopDiscovery();
  }

  /// Stops the UWB session with the device
  /// [device] is the device to stop the session with
  @override
  Future<void> stopRanging(UwbDevice device) async {
    try {
      if (!_discoveredDevices.containsKey(device.id)) {
        _discoveredDevices.remove(device.id);
        _discoveredDevicesStream.add(_discoveredDevices.values);
      }

      await _hostApi.stopRanging(device);

      if (_rangingDevices.containsKey(device.id)) {
        _rangingDevices.remove(device.id);
        _rangingDevicesStream.add(_rangingDevices.values);

        _uwbSessionStateStream.add(
          UwbSessionDisconnectedState(device),
        );
      }
    } on PlatformException catch (e) {
      return await Future.error(e);
    }
  }

  @override
  Future<void> stopUwbSessions() async {
    try {
      _rangingDevices.clear();
      return await _hostApi.stopUwbSessions();
    } on PlatformException catch (e) {
      return Future.error(e);
    }
  }

  /// Whether the device supports UWB or not
  @override
  Future<bool> isUwbSupported() async {
    return await _hostApi.isUwbSupported();
  }

  /// Connects to a device and starts ranging
  /// [device] is the device to connect to
  @override
  Future<void> startRanging(UwbDevice device) async {
    try {
      return await _hostApi.startRanging(device);
    } on PlatformException catch (e) {
      _parsePlatformException(e);
    }
  }

  /// Accepts or rejects a connection request from a device
  /// Use this method after receiving a [DeviceInvitedState]
  /// from the [discoveryStateStream].
  /// [device] is the device to accept or reject the connection request from
  @override
  Future<void> handleConnectionRequest(UwbDevice device, bool accept) async {
    try {
      return await _hostApi.handleConnectionRequest(device, accept);
    } on PlatformException catch (e) {
      _parsePlatformException(e);
    }
  }

  void dispose() {}

  void _parsePlatformException(PlatformException e) {
    throw UwbException(ErrorCode.values[int.parse(e.code)], e.message);
  }

  UwbDevice _parseUwbData(String data) {
    Map<String, dynamic> jsonData = jsonDecode(data.toString());
    String id = jsonData['id'].toString();
    String name = jsonData['name'].toString();

    // Available: Apple API
    Direction3D? direction;
    if (jsonData['directionX'] != null && jsonData['directionY'] != null && jsonData['directionZ'] != null) {
      direction = Direction3D(
        x: jsonData['directionX'],
        y: jsonData['directionY'],
        z: jsonData['directionZ'],
      );
    }

    // Available: Android and Apple API
    double? distance;
    if (jsonData['distance'] != null) {
      distance = double.tryParse(
        jsonData['distance'].toString(),
      );
    }

    // Available: Android API and Apple Accessory API
    double? azimuth;
    if (jsonData['azimuth'] != null) {
      azimuth = double.tryParse(
        jsonData['azimuth'].toString(),
      );
    }

    // Available: Android API and Apple Accessory API
    double? elevation;
    if (jsonData['elevation'] != null) {
      elevation = double.tryParse(
        jsonData['elevation'].toString(),
      );
    }

    // Available: Apple API
    double? horizontalAngle;
    if (jsonData['horizontalAngle'] != null) {
      horizontalAngle = double.tryParse(
        jsonData['horizontalAngle'].toString(),
      );
    }

    // convert elevation and azimuth to direction
    // check if direction is null
    /*if (azimuth != null && elevation != null) {
      //direction = Math.toDirection3D(azimuth, elevation);
      var angle = azimuth * (pi / 180.0);
      var x = distance! * sin(angle);
      var y = distance * cos(angle);
      direction = Direction3D(x: x, y: y, z: 0);
    }*/

    DeviceType deviceType = DeviceType.smartphone;
    if (jsonData['deviceType'] != null) {
      deviceType = DeviceType.values[jsonData['deviceType']];
    }

    return UwbDevice(
      id: id,
      name: name,
      uwbData: UwbData(
        distance: distance,
        azimuth: azimuth,
        elevation: elevation,
        direction: direction,
        horizontalAngle: horizontalAngle,
      ),
      deviceType: deviceType,
    );
  }
}
