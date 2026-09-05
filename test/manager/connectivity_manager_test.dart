import 'dart:async';

import 'package:fl_clash/manager/connectivity_manager.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stale SSID reads cannot restore Wi-Fi after a network change', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    globalState.container = container;
    var ssid = Completer<String?>();
    late MockStreamHandlerEventSink events;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('wifi_ssid'),
      (_) => ssid.future,
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (_, sink) => events = sink),
    );
    await tester.pumpWidget(const ConnectivityManager(child: SizedBox()));
    await tester.pump();

    events.success(['wifi']);
    await tester.pump();
    events.success(['mobile']);
    await tester.pump();
    ssid.complete('Excluded Wi-Fi');
    await tester.pump();

    expect(container.read(currentSSIDProvider), isNull);
    ssid = Completer<String?>();
    events.success(['wifi']);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    ssid.complete('Excluded Wi-Fi');
    await tester.pump();
    expect(container.read(currentSSIDProvider), isNull);
  });
}
