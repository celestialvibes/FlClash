import 'package:fl_clash/common/updater.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('macOS update check delegates to Sparkle', () async {
    const channel = MethodChannel('com.loomhost.client/updater');
    MethodCall? call;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (value) async {
          call = value;
        });

    await checkForAppUpdates();

    expect(call?.method, 'checkForUpdates');
  });
}
