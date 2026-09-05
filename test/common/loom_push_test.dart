import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fl_clash/common/loom_device_credential.dart';
import 'package:fl_clash/common/loom_push.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  test(
    'push stop invalidates initialization before listeners are installed',
    () async {
      final messaging = _Messaging();
      final initialization = Completer<FirebaseMessaging?>();
      final push = _TestPush(() => initialization.future);
      final start = push.start(appVersion: '1', appBuild: '1');
      await push.start(appVersion: '1', appBuild: '1');
      expect(push.initializations, 1);
      await push.stop();
      initialization.complete(messaging);
      await start;
      verifyNever(() => messaging.requestPermission());
    },
  );

  test('an old permission failure cannot stop a newer push start', () async {
    final messaging = _Messaging();
    final oldPermission = Completer<NotificationSettings>();
    final newPermission = Completer<NotificationSettings>();
    final permissions = [oldPermission, newPermission];
    final tokens = StreamController<String>.broadcast();
    addTearDown(tokens.close);
    when(
      () => messaging.requestPermission(),
    ).thenAnswer((_) => permissions.removeAt(0).future);
    when(() => messaging.onTokenRefresh).thenAnswer((_) => tokens.stream);
    when(() => messaging.getInitialMessage()).thenAnswer((_) async => null);
    final push = _TestPush(() async => messaging);
    addTearDown(push.stop);
    final oldStart = push.start(appVersion: '1', appBuild: '1');
    await Future<void>.delayed(Duration.zero);
    await push.stop();
    final newStart = push.start(appVersion: '1', appBuild: '1');
    await Future<void>.delayed(Duration.zero);
    oldPermission.completeError(StateError('old permission request failed'));
    await oldStart;
    newPermission.complete(_Settings());
    await newStart;
    expect(tokens.hasListener, isTrue);
    await push.stop();
    expect(tokens.hasListener, isFalse);
  });

  test('device credentials are valid 256-bit base64url values', () {
    final credential = generateLoomDeviceCredential(Random(1));

    expect(isLoomDeviceCredential(credential), isTrue);
    expect(credential, hasLength(43));
  });

  test('Firebase options require every value', () {
    expect(
      createLoomFirebaseOptions(
        apiKey: 'key',
        projectId: 'project',
        appId: '',
        messagingSenderId: 'sender',
      ),
      isNull,
    );
    expect(
      createLoomFirebaseOptions(
        apiKey: 'key',
        projectId: 'project',
        appId: 'app',
        messagingSenderId: 'sender',
      ),
      isNotNull,
    );
  });

  test('push routes accept only internal allowlisted destinations', () {
    expect(parseLoomPushRoute({'cta': 'support'}), LoomPushRoute.support);
    expect(parseLoomPushRoute({'cta': 'plans'}), LoomPushRoute.subscription);
    expect(parseLoomPushRoute({'route': 'https://evil.example'}), isNull);
  });

  test('FCM token registration is device-authenticated', () async {
    late RequestOptions request;
    final dio = Dio();
    dio.httpClientAdapter = _ResponseAdapter((options) {
      request = options;
      return ResponseBody.fromString('', 204);
    });
    const credential = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

    await registerLoomPushToken(
      dio: dio,
      deviceCredential: credential,
      token: 'fcm-token',
      appVersion: '0.2.0',
      appBuild: '22',
    );

    expect(request.method, 'PUT');
    expect(request.path, endsWith('/api/v1/device/push-token'));
    expect(request.headers['Authorization'], 'Bearer $credential');
    expect(request.data, {
      'provider': 'fcm',
      'token': 'fcm-token',
      'platform': 'android',
      'app_version': '0.2.0',
      'app_build': '22',
    });
  });
}

class _Messaging extends Mock implements FirebaseMessaging {}

class _Settings extends Fake implements NotificationSettings {}

class _TestPush extends LoomPush {
  final Future<FirebaseMessaging?> Function() initialize;
  int initializations = 0;

  _TestPush(this.initialize);

  @override
  Future<FirebaseMessaging?> messagingForStart() {
    initializations++;
    return initialize();
  }

  @override
  Future<void> syncToken([String? refreshedToken]) async {}
}

final class _ResponseAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) response;

  _ResponseAdapter(this.response);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => response(options);

  @override
  void close({bool force = false}) {}
}
