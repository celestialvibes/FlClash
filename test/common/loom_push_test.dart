import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/loom_device_credential.dart';
import 'package:fl_clash/common/loom_push.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
