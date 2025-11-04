import 'package:flutter/material.dart';
import 'package:uwb/flutter_uwb.dart';
import 'dart:math';

// TODO: Callback to notify the parent widget to update the list

class UwbListItem extends StatelessWidget {
  final UwbDevice device;
  final Uwb uwbPlugin;

  const UwbListItem({
    Key? key,
    required this.device,
    required this.uwbPlugin,
  }) : super(key: key);

  String getDirection(UwbDevice device) {
    if (device.uwbData == null) {
      return "X: null Y: null Z: null";
    }

    var data = device.uwbData!;
    if (data.direction?.x != null && data.direction?.y != null && data.direction?.z != null) {
      var x = data.direction?.x.toStringAsFixed(1);
      var y = data.direction?.y.toStringAsFixed(1);
      var z = data.direction?.z.toStringAsFixed(1);
      return "X: $x Y: $y Z: $z";
    }
    return "X: 0 Y: 0 Z: 0";
  }

  String getDistance(UwbDevice device) {
    if (device.uwbData == null) {
      return "📍 null";
    }

    var distance = device.uwbData!.distance?.toStringAsFixed(2);
    return "📍 ${distance}m";
  }

  String getHorizontalAngle(UwbDevice device) {
    if (device.uwbData == null) {
      return "null (Horizontal)";
    }

    var angle = device.uwbData!.horizontalAngle?.toStringAsFixed(1);
    if (device.uwbData!.horizontalAngle != null) {
      return "$angle° (Horizontal)";
    }
    return "null  (Horizontal)";
  }

  String getFiraData(UwbDevice device) {
    if (device.uwbData == null) {
      return "E: null A: null";
    }

    var data = device.uwbData!;
    var elevation = data.elevation?.toStringAsFixed(1);
    var azimuth = data.azimuth?.toStringAsFixed(1);
    return "E: $elevation° A: $azimuth°";
  }

  String getDeviceIcon(UwbDevice device) {
    String icon = "📟";
    if (device.deviceType == DeviceType.smartphone) {
      icon = "📱";
    }
    return icon;
  }

  double getAngle(UwbDevice device) {
    if (device.uwbData == null) {
      return 0;
    }

    if (device.uwbData!.azimuth != null) {
      var azimuth = device.uwbData!.azimuth!;
      return azimuth * (pi / 180);
    }

    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Column(
              children: [
                Text(
                  getDeviceIcon(device),
                  style: const TextStyle(
                    fontSize: 24,
                  ),
                ),
              ],
            ),
            title: Text(
              "${device.name}",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Container(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Icon(Icons.assistant_navigation),
                      const SizedBox(width: 10),
                      Text(
                        getDirection(device),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Transform.rotate(
                        angle: getAngle(device),
                        child: const Icon(Icons.assistant_navigation),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        getFiraData(device),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Icon(Icons.text_rotation_angledown),
                      const SizedBox(width: 10),
                      Text(
                        getHorizontalAngle(device),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            trailing: Text(
              getDistance(device),
              style: const TextStyle(
                fontSize: 16,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              const SizedBox(width: 8),
              TextButton(
                child: const Text('Stop Uwb Ranging'),
                onPressed: () {
                  uwbPlugin.stopRanging(device);
                },
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
    );
  }
}
