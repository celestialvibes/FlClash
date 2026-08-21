import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/loom_auth.dart';
import 'package:flutter_test/flutter_test.dart';

const _deviceCredential = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

void main() {
  test('Telegram approval returns the current device Mihomo URL', () async {
    final requests = <RequestOptions>[];
    var statusCalls = 0;
    final dio = Dio();
    dio.httpClientAdapter = _ResponseAdapter((options) {
      requests.add(options);
      return switch (options.path) {
        final path when path.endsWith('/api/v1/auth/telegram/start') =>
          _jsonResponse({
            'public_token': 'aBcDeFgHiJkLmNoPqRsTuVwXyZ012345',
            'authorization_url':
                'https://oauth.telegram.org/auth?client_id=123&redirect_uri=https%3A%2F%2Floomvpn.pro%2Fapi%2Fv1%2Fauth%2Ftelegram%2Fcallback&state=0123456789abcdef&response_type=code&scope=openid%20profile&code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&code_challenge_method=S256',
            'expires_in_seconds': 300,
          }),
        final path when path.endsWith('/api/v1/auth/telegram/status') =>
          ++statusCalls == 1
              ? _jsonResponse({'status': 'pending'})
              : _jsonResponse({
                  'status': 'approved',
                  'device_id': 'e30218a7-3d3b-4b50-920e-a6ee55211db3',
                  'config_url': 'https://lmvn.pro/Ab3dE/mihomo',
                }),
        _ => _jsonResponse({}, statusCode: 404),
      };
    });
    final client = LoomAuthClient(
      platform: 'windows',
      appVersion: '1.0.0',
      appBuild: '16',
      dio: dio,
      deviceCredential: () async => _deviceCredential,
    );
    const installationId = '65af74c6-40f7-46b7-936b-724256aff099';

    final challenge = await client.requestTelegramLogin(
      installationId: installationId,
    );
    expect(await client.pollTelegramLogin(challenge), isNull);
    final activation = await client.pollTelegramLogin(challenge);

    expect(activation?.subscriptionUrl, 'https://lmvn.pro/Ab3dE/mihomo');
    expect(requests.first.data, containsPair('device_key', installationId));
    expect(requests.first.data, containsPair('platform', 'windows'));
    expect(
      requests.first.data,
      containsPair('device_credential', _deviceCredential),
    );
    expect(requests.last.data, {'public_token': challenge.publicToken});
  });

  test('email OTP registers one installation and returns Mihomo URL', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.httpClientAdapter = _ResponseAdapter((options) {
      requests.add(options);
      return switch (options.path) {
        final path when path.endsWith('/api/v1/auth/request-code') =>
          _jsonResponse({
            'code_id': '1934cec1-6f06-4dc6-a080-a820209a2e7a',
            'expires_in_seconds': 900,
          }),
        final path when path.endsWith('/api/v1/auth/verify-code') =>
          _jsonResponse(
            {'user_id': 'fc2d68d5-758d-4f18-8b50-07c27c3d110e'},
            headers: {
              'set-cookie': [
                'session=opaque-session; HttpOnly; Secure; SameSite=Lax',
              ],
            },
          ),
        final path when path.endsWith('/api/v1/me/access') => _jsonResponse({
          'status': 'active',
        }),
        final path when path.endsWith('/api/v1/devices') => _jsonResponse({
          'device_id': 'e30218a7-3d3b-4b50-920e-a6ee55211db3',
          'config_url': 'https://lmvn.pro/Ab3dE',
        }),
        _ => _jsonResponse({}, statusCode: 404),
      };
    });
    final client = LoomAuthClient(
      platform: 'android',
      appVersion: '1.0.0',
      appBuild: '15',
      dio: dio,
      deviceCredential: () async => _deviceCredential,
    );

    final challenge = await client.requestCode(' USER@Example.com ');
    final activation = await client.activate(
      challenge: challenge,
      code: '123456',
      installationId: '65af74c6-40f7-46b7-936b-724256aff099',
    );

    expect(activation.subscriptionUrl, 'https://lmvn.pro/Ab3dE/mihomo');
    expect(requests.first.data, {'email': 'user@example.com'});
    expect(requests[2].headers['Cookie'], 'session=opaque-session');
    expect(requests[3].headers['Cookie'], 'session=opaque-session');
    expect(
      requests[3].data,
      containsPair('device_key', '65af74c6-40f7-46b7-936b-724256aff099'),
    );
    expect(
      requests[3].data,
      containsPair('device_credential', _deviceCredential),
    );
  });

  test('rate limiting is exposed as a typed failure', () async {
    final dio = Dio();
    dio.httpClientAdapter = _ResponseAdapter(
      (_) => _jsonResponse({'error': 'rate_limited'}, statusCode: 429),
    );
    final client = LoomAuthClient(
      platform: 'macos',
      appVersion: '1.0.0',
      appBuild: '15',
      dio: dio,
    );

    await expectLater(
      client.requestCode('user@example.com'),
      throwsA(
        isA<LoomAuthException>().having(
          (error) => error.failure,
          'failure',
          LoomAuthFailure.rateLimited,
        ),
      ),
    );
  });
}

ResponseBody _jsonResponse(
  Map<String, Object?> body, {
  int statusCode = 200,
  Map<String, List<String>> headers = const {},
}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
      ...headers,
    },
  );
}

final class _ResponseAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) response;

  _ResponseAdapter(this.response);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return response(options);
  }

  @override
  void close({bool force = false}) {}
}
