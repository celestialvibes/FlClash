import 'package:fl_clash/common/system.dart';
import 'package:flutter/services.dart';

const _updaterChannel = MethodChannel('com.loomhost.client/updater');

Future<void> checkForAppUpdates() async {
  if (!system.isMacOS) return;
  await _updaterChannel.invokeMethod<void>('checkForUpdates');
}
