import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:rxdart/subjects.dart';
import 'package:uwb/flutter_uwb.dart';
import 'package:uwb_example/navigator_key.dart';
import 'package:uwb_example/settings.dart';
import 'package:uwb_example/widgets/uwb_listitem.dart';

class RangingPage extends StatefulWidget {
  final Uwb uwbPlugin;
  final String deviceName;

  // Dirty Hack: EventChannel only accepts a single listener

  const RangingPage({super.key, required this.uwbPlugin, required this.deviceName});

  @override
  State<RangingPage> createState() => _RangingPage();
}

class _RangingPage extends State<RangingPage> {
  bool _isUwbSupported = false;

  final BehaviorSubject<Iterable<UwbDevice>> _discoveredDevicesStream = BehaviorSubject<Iterable<UwbDevice>>();

  final Map<String, UwbDevice> _devices = {};
  bool _isDiscovering = false;
  bool _showDebugConsole = false;
  bool _autoAcceptInvites = true;
  final List<String> _debugLogs = <String>[];
  final EventChannel _debugLogChannel = const EventChannel('uwb_plugin/debug_logs');
  StreamSubscription<dynamic>? _debugSub;

  void _addLog(String entry) {
    final time = DateTime.now().toIso8601String();
    setState(() {
      _debugLogs.insert(0, "[$time] $entry");
      if (_debugLogs.length > 200) _debugLogs.removeRange(200, _debugLogs.length);
    });
  }

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  @override
  void setState(fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    if (!mounted) return;

    _debugSub = _debugLogChannel.receiveBroadcastStream().listen((log) {
      _addLog(log as String);
    }, onError: (error) {
      _addLog("Debug log stream error: $error");
    });

    try {
      _isUwbSupported = await widget.uwbPlugin.isUwbSupported();
      debugPrint("[APP] UWB Supported: $_isUwbSupported");
      _addLog("UWB Supported: $_isUwbSupported");
    } catch (e) {
      debugPrint("[APP] Error checking UWB support: $e");
      _isUwbSupported = false;
      _addLog("Error checking UWB support: $e");
    }

    widget.uwbPlugin.discoveryStateStream.listen((event) {
      debugPrint("[APP] Discovery State: $event");
      _addLog("Discovery State: $event");
      switch (event) {
        case DeviceConnectedState(device: var device):
          debugPrint("[APP] Device Connected: ${device.name} ${device.id} ${device.state}");
          break;
        case DeviceFoundState(device: var device):
          debugPrint("[APP] Device Found: ${device.name} ${device.id} ${device.state}");
          break;
        case DeviceInvitedState(device: var device):
          debugPrint("[APP] Device Invited: ${device.name} ${device.id} ${device.state}");
          onDiscoveryDeviceInvited(device);
          break;
        case DeviceInviteRejected(device: var device):
          debugPrint("[APP] Device Invited rejected: ${device.id} ${device.state}");
          showErrorDialog("Rejected", "Device rejected.");
          break;
        case DeviceDisconnectedState(device: var device):
          setState(() {
            _devices.remove(device.id);
          });
          debugPrint("[APP] Device disconnected: ${device.name} ${device.id} ${device.state}");
          break;
        case DeviceLostState(device: var device):
          debugPrint("[APP] Device Lost: ${device.id} ${device.state}");
          break;
      }
    });

    widget.uwbPlugin.uwbSessionStateStream.listen(
      (event) {
        _addLog("UWB Session State: $event");
        switch (event) {
          case UwbSessionStartedState(device: var device):
            debugPrint("[APP] Uwb Session Started: ${device.id} ${device.state}");
            setState(() {
              _devices[device.id] = device;
            });
            break;
          case UwbSessionDisconnectedState(device: var device):
            debugPrint("[APP] Device Disconnected: ${device.id} ${device.state}");
            setState(() {
              _devices.remove(device.id);
            });
            showErrorDialog("UWB Disconnected", "UWB Session disconnected for ${device.name}");
            break;
        }
      },
    );

    _discoveredDevicesStream.addStream(widget.uwbPlugin.discoveredDevicesStream);

    uwbDataStream.asBroadcastStream().listen((devices) {
      setState(() {
        devices.map((e) => {_devices[e.id] = e}).toList();
      });
    });

    // Start discovery automatically to make it easy to test phone<->phone
    // discovery on two devices. This will call the native side to start
    // MultipeerConnectivity advertising and discovery + BLE accessory scan.
    try {
      debugPrint('[APP] Auto-starting discovery with name: ${widget.deviceName}');
      await widget.uwbPlugin.discoverDevices(widget.deviceName);
      setState(() {
        _isDiscovering = true;
      });
      _addLog('Auto-started discovery with name: ${widget.deviceName}');
    } catch (e) {
      debugPrint('[APP] Auto discovery failed: $e');
      _addLog('Auto discovery failed: $e');
    }
  }

  @override
  void dispose() async {
    await _debugSub?.cancel();
    await _discoveredDevicesStream.drain();
    _discoveredDevicesStream.close();
    super.dispose();
  }

  Widget getListCardAction(UwbDevice device) {
    if (device.state == DeviceState.found || device.state == DeviceState.disconnected) {
      return ElevatedButton(
        onPressed: () async {
          try {
            debugPrint("starting ranging to device: ${device.id}");
            await widget.uwbPlugin.startRanging(device);
          } on PlatformException catch (e) {
            showErrorDialog("Error", "Error: ${e.code} ${e.message}");
          }
        },
        child: const Text(
          "Connect",
        ),
      );
    }

    if (device.state == DeviceState.connected) {
      return ElevatedButton(
        onPressed: () async {
          try {
            await widget.uwbPlugin.startRanging(device);
          } on PlatformException catch (e) {
            showErrorDialog("Error", "Error: ${e.code} ${e.message}");
          }
        },
        child: const Text(
          "Start Ranging",
        ),
      );
    }

    if (device.state == DeviceState.ranging) {
      return ElevatedButton(
        onPressed: () async {
          try {
            await widget.uwbPlugin.stopRanging(device);
          } on PlatformException catch (e) {
            showErrorDialog("Error", "Error: ${e.code} ${e.message}");
          }
        },
        child: const Text(
          "Stop Ranging",
        ),
      );
    }

    if (device.state == DeviceState.pending) {
      return const Text(
        "Pending",
      );
    }

    return const Text(
      "Unknown",
    );
  }

  void onPermissionRequired(PermissionAction action) {
    debugPrint("Permission required: $action");
    String actionDescription = "";

    if (action == PermissionAction.request) {
      actionDescription = "You need to grant the permission to use UWB for this app.";
    } else {
      actionDescription = "You need to grant the permission and restart the app to use UWB.";
    }

    showErrorDialog("Permission Required", actionDescription);
  }

  void showErrorDialog(String title, String description) {
    showDialog(
      context: navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text("Ok"),
          ),
        ],
      ),
    );
  }

  void onDiscoveryDeviceInvited(UwbDevice device) async {
    debugPrint("Device invited: ${device.id}");
    _addLog("Device invited: ${device.id}");
    if (_autoAcceptInvites) {
      // Auto-accept path
      _addLog("Auto-accepting invitation for ${device.id}");
      try {
        await widget.uwbPlugin.handleConnectionRequest(device, true);
      } on UwbException catch (e) {
        showErrorDialog("Error", "Error: ${e.code} ${e.message}");
        _addLog("Error handling connection request: ${e.code} ${e.message}");
      }
      return;
    }

    // Manual accept: show a confirmation dialog to the user
    final accept = await showDialog<bool>(
      context: navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('Incoming connection'),
        content: Text('Accept connection request from ${device.name} (${device.id})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Reject'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    if (accept == true) {
      try {
        await widget.uwbPlugin.handleConnectionRequest(device, true);
      } on UwbException catch (e) {
        showErrorDialog("Error", "Error: ${e.code} ${e.message}");
        _addLog("Error handling connection request: ${e.code} ${e.message}");
      }
    } else {
      try {
        await widget.uwbPlugin.handleConnectionRequest(device, false);
      } on UwbException catch (e) {
        _addLog("Error rejecting connection request: ${e.code} ${e.message}");
      }
    }
  }

  void _copyLogsToClipboard() {
    final text = _debugLogs.join('\n');
    Clipboard.setData(ClipboardData(text: text));
    final count = _debugLogs.length;
    ScaffoldMessenger.of(navigatorKey.currentContext!).showSnackBar(
      SnackBar(content: Text('Copied $count log${count == 1 ? '' : 's'} to clipboard')),
    );
  }

  String _getDeviceTypeIcon(UwbDevice device) {
    if (device.deviceType == DeviceType.smartphone) {
      return "📱";
    }
    return "📟";
  }

  void showDiscoveryModal() {
    showModalBottomSheet<void>(
      isScrollControlled: true,
      enableDrag: true,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(40.0),
      ),
      context: context,
      builder: (BuildContext context) {
        return SizedBox(
          height: 400,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.only(bottom: 10),
                child: const Text(
                  "🔍 Nearby Devices",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  "My Device: ${widget.deviceName}",
                ),
              ),
              SizedBox(
                height: 250,
                child: StreamBuilder<Iterable<UwbDevice>>(
                  stream: _discoveredDevicesStream.stream,
                  builder: (context, snapshot) {
                    final devices = snapshot.data?.toList() ?? [];
                    if (devices.isNotEmpty) {
                      return ListView.builder(
                        padding: const EdgeInsets.only(top: 10),
                        itemCount: devices.length,
                        itemBuilder: (context, index) {
                          final device = devices[index];
                          return Card(
                            color: Colors.white,
                            child: ListTile(
                              title: Text(
                                "${_getDeviceTypeIcon(device)} ${device.name} (${device.id}) (${device.state})",
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: getListCardAction(device),
                            ),
                          );
                        },
                      );
                    }
                    return const Center(
                      child: Text("No nearby devices found"),
                    );
                  },
                ),
              ),
              ElevatedButton(
                child: const Text('Close'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      "UWB Sessions",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text('MPC Service: uwb-app-test-id', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Text('MPC Identity: uwb-identity', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _isDiscovering ? Colors.greenAccent.withOpacity(0.12) : Colors.grey.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isDiscovering ? Icons.wifi : Icons.wifi_off,
                      color: _isDiscovering ? Colors.green : Colors.grey,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isDiscovering ? 'Discovering' : 'Idle',
                      style: TextStyle(
                        fontSize: 12,
                        color: _isDiscovering ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Expanded(child: Builder(
            builder: (context) {
              if (_devices.isNotEmpty) {
                return ListView.builder(
                  itemCount: _devices.length,
                  itemBuilder: (context, index) {
                    return UwbListItem(
                      device: _devices.values.toList()[index],
                      uwbPlugin: widget.uwbPlugin,
                    );
                  },
                );
              }
              return const Card(
                color: Colors.white,
                child: ListTile(
                  title: Text("No active UWB Sessions"),
                ),
              );
            },
          )),
          Container(
            alignment: Alignment.center,
            child: Wrap(
              children: [
                ElevatedButton(
                  onPressed: _isDiscovering
                      ? null
                      : () async {
                          showDiscoveryModal();
                          try {
                            debugPrint("starting device discovery for name: ${widget.deviceName}");
                            await widget.uwbPlugin.discoverDevices(widget.deviceName);
                            setState(() {
                              _isDiscovering = true;
                            });
                            _addLog('Manual start discovery with name: ${widget.deviceName}');
                          } on UwbException catch (e) {
                            showErrorDialog("Error", "${e.code} ${e.message}");
                          }
                        },
                  child: _isDiscovering ? const Text('Discovering...') : const Text('Search'),
                ),
                ElevatedButton(
                  onPressed: _isDiscovering
                      ? () async {
                          await widget.uwbPlugin.stopDiscovery();
                          setState(() {
                            _isDiscovering = false;
                          });
                          _addLog('Stopped discovery');
                        }
                      : null,
                  child: const Text('Stop Search'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _showDebugConsole = !_showDebugConsole;
                    });
                  },
                  child: Text(_showDebugConsole ? 'Hide Logs' : 'Show Logs'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _debugLogs.isNotEmpty ? _copyLogsToClipboard : null,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy Logs'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () async {
                    final channel = MethodChannel('uwb_plugin/diagnostics');
                    try {
                      await channel.invokeMethod('dumpMpcHealth');
                      _addLog('Requested MPC health dump');
                    } catch (e) {
                      _addLog('Failed requesting health dump: $e');
                    }
                  },
                  icon: const Icon(Icons.bug_report, size: 18),
                  label: const Text('Dump MPC'),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Auto-Accept'),
                    Switch.adaptive(
                      value: _autoAcceptInvites,
                      onChanged: (v) {
                        setState(() {
                          _autoAcceptInvites = v;
                        });
                        _addLog('Auto-Accept set to: $v');
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_showDebugConsole)
            Container(
              margin: const EdgeInsets.only(top: 10),
              height: 160,
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                reverse: true,
                itemCount: _debugLogs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                    child: Text(
                      _debugLogs[index],
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
