import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

class ConnectivityManager extends StatefulWidget {
  final Function(List<ConnectivityResult> results)? onConnectivityChanged;
  final Widget child;

  const ConnectivityManager({
    super.key,
    this.onConnectivityChanged,
    required this.child,
  });

  @override
  State<ConnectivityManager> createState() => _ConnectivityManagerState();
}

class _ConnectivityManagerState extends State<ConnectivityManager> {
  late StreamSubscription subscription;
  int _networkRevision = 0;

  @override
  void initState() {
    super.initState();
    subscription = Connectivity().onConnectivityChanged.listen((results) {
      final revision = ++_networkRevision;
      if (results.contains(ConnectivityResult.wifi)) {
        unawaited(_updateSsid(revision));
      } else {
        globalState.container.read(currentSSIDProvider.notifier).value = null;
      }
      if (widget.onConnectivityChanged != null) {
        widget.onConnectivityChanged!(results);
      }
    });
  }

  Future<void> _updateSsid(int revision) async {
    String? ssid;
    try {
      ssid = await WifiSsidManager.instance.getSsid();
    } catch (_) {
      ssid = null;
    }
    if (!mounted || revision != _networkRevision) return;
    globalState.container.read(currentSSIDProvider.notifier).value = ssid;
  }

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
