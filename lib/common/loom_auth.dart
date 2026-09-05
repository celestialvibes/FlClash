import 'dart:io';

import 'package:dio/dio.dart';

import 'link.dart';
import 'loom_device_credential.dart';
import 'loom_support.dart';
import 'preferences.dart';
import 'utils.dart';

const _installationIdKey = 'loomInstallationIdV1';
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

enum LoomAuthFailure {
  invalidCode,
  expiredCode,
  authorizationExpired,
  rateLimited,
  subscriptionMissing,
  deviceLimit,
  network,
  invalidResponse,
}

class LoomAuthException implements Exception {
  final LoomAuthFailure failure;

  const LoomAuthException(this.failure);
}

class LoomLoginChallenge {
  final String id;
  final int expiresInSeconds;

  const LoomLoginChallenge({required this.id, required this.expiresInSeconds});
}

class LoomTelegramChallenge {
  final String publicToken;
  final String authorizationUrl;
  final int expiresInSeconds;

  const LoomTelegramChallenge({
    required this.publicToken,
    required this.authorizationUrl,
    required this.expiresInSeconds,
  });
}

class LoomActivation {
  final String deviceId;
  final String subscriptionUrl;

  const LoomActivation({required this.deviceId, required this.subscriptionUrl});
}

Future<String> loomInstallationId() async {
  final stored = await preferences.getString(_installationIdKey);
  if (stored != null && _uuidPattern.hasMatch(stored)) return stored;
  final generated = utils.uuidV4;
  if (!await preferences.setString(_installationIdKey, generated)) {
    throw const LoomAuthException(LoomAuthFailure.invalidResponse);
  }
  return generated;
}

class LoomAuthClient {
  final String platform;
  final String appVersion;
  final String appBuild;
  final Dio _dio;
  final Future<String?> Function()? _deviceCredential;

  LoomAuthClient({
    required this.platform,
    required this.appVersion,
    required this.appBuild,
    Dio? dio,
    Future<String?> Function()? deviceCredential,
  }) : _dio = dio ?? createLoomApiDio(),
       _deviceCredential = deviceCredential;

  Future<LoomTelegramChallenge> requestTelegramLogin({
    required String installationId,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        loomSupportApiUri.resolve('/api/v1/auth/telegram/start').toString(),
        data: {
          'platform': platform,
          'label': _deviceLabel(platform, installationId),
          'device_key': installationId,
          'app_version': appVersion,
          'app_build': appBuild,
          ...await _deviceCredentialPayload(),
        },
      );
      final data = _map(response.data);
      final publicToken = data['public_token'];
      final authorizationUrl = data['authorization_url'];
      final expiresInSeconds = data['expires_in_seconds'];
      if (publicToken is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(publicToken) ||
          authorizationUrl is! String ||
          !_isTelegramAuthorizationUrl(authorizationUrl) ||
          expiresInSeconds is! num ||
          expiresInSeconds <= 0 ||
          expiresInSeconds > 900) {
        throw const LoomAuthException(LoomAuthFailure.invalidResponse);
      }
      return LoomTelegramChallenge(
        publicToken: publicToken,
        authorizationUrl: authorizationUrl,
        expiresInSeconds: expiresInSeconds.toInt(),
      );
    } on DioException catch (error) {
      throw _failure(error);
    }
  }

  Future<LoomActivation?> pollTelegramLogin(
    LoomTelegramChallenge challenge, {
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        loomSupportApiUri.resolve('/api/v1/auth/telegram/status').toString(),
        data: {'public_token': challenge.publicToken},
        cancelToken: cancelToken,
      );
      final data = _map(response.data);
      switch (data['status']) {
        case 'pending':
          return null;
        case 'expired':
          throw const LoomAuthException(LoomAuthFailure.authorizationExpired);
        case 'approved':
          final deviceId = data['device_id'];
          final configUrl = data['config_url'];
          if (deviceId is! String ||
              !_uuidPattern.hasMatch(deviceId) ||
              configUrl is! String) {
            throw const LoomAuthException(LoomAuthFailure.invalidResponse);
          }
          return LoomActivation(
            deviceId: deviceId,
            subscriptionUrl: _mihomoUrl(configUrl),
          );
        default:
          throw const LoomAuthException(LoomAuthFailure.invalidResponse);
      }
    } on DioException catch (error) {
      if (error.response?.statusCode == HttpStatus.notFound) {
        throw const LoomAuthException(LoomAuthFailure.authorizationExpired);
      }
      throw _failure(error);
    }
  }

  Future<LoomLoginChallenge> requestCode(String email) async {
    try {
      final response = await _dio.post<Object?>(
        loomSupportApiUri.resolve('/api/v1/auth/request-code').toString(),
        data: {'email': email.trim().toLowerCase()},
      );
      final data = _map(response.data);
      final id = data['code_id'];
      final expiresInSeconds = data['expires_in_seconds'];
      if (id is! String ||
          !_uuidPattern.hasMatch(id) ||
          expiresInSeconds is! num ||
          expiresInSeconds <= 0) {
        throw const LoomAuthException(LoomAuthFailure.invalidResponse);
      }
      return LoomLoginChallenge(
        id: id,
        expiresInSeconds: expiresInSeconds.toInt(),
      );
    } on DioException catch (error) {
      throw _failure(error);
    }
  }

  Future<LoomActivation> activate({
    required LoomLoginChallenge challenge,
    required String code,
    required String installationId,
  }) async {
    try {
      final verified = await _dio.post<Object?>(
        loomSupportApiUri.resolve('/api/v1/auth/verify-code').toString(),
        data: {'code_id': challenge.id, 'code': code},
      );
      final session = _sessionCookie(verified.headers);
      final options = Options(headers: {'Cookie': 'session=$session'});
      final access = await _dio.get<Object?>(
        loomSupportApiUri.resolve('/api/v1/me/access').toString(),
        options: options,
      );
      if (_map(access.data)['status'] != 'active') {
        throw const LoomAuthException(LoomAuthFailure.subscriptionMissing);
      }
      final registered = await _dio.post<Object?>(
        loomSupportApiUri.resolve('/api/v1/devices').toString(),
        data: {
          'platform': platform,
          'label': _deviceLabel(platform, installationId),
          'device_key': installationId,
          'app_version': appVersion,
          'app_build': appBuild,
          ...await _deviceCredentialPayload(),
        },
        options: options,
      );
      final data = _map(registered.data);
      final deviceId = data['device_id'];
      final configUrl = data['config_url'];
      if (deviceId is! String ||
          !_uuidPattern.hasMatch(deviceId) ||
          configUrl is! String) {
        throw const LoomAuthException(LoomAuthFailure.invalidResponse);
      }
      final subscriptionUrl = _mihomoUrl(configUrl);
      return LoomActivation(
        deviceId: deviceId,
        subscriptionUrl: subscriptionUrl,
      );
    } on DioException catch (error) {
      throw _failure(error);
    }
  }

  Future<Map<String, String>> _deviceCredentialPayload() async {
    final value = await _deviceCredential?.call();
    if (value == null) return const {};
    if (!isLoomDeviceCredential(value)) {
      throw const LoomAuthException(LoomAuthFailure.invalidResponse);
    }
    return {'device_credential': value};
  }
}

bool _isTelegramAuthorizationUrl(String value) {
  final uri = Uri.tryParse(value);
  final redirectUri = Uri.tryParse(uri?.queryParameters['redirect_uri'] ?? '');
  final state = uri?.queryParameters['state'] ?? '';
  final codeChallenge = uri?.queryParameters['code_challenge'] ?? '';
  final scopes = (uri?.queryParameters['scope'] ?? '').split(' ');
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'oauth.telegram.org' &&
      uri.path == '/auth' &&
      RegExp(r'^\d+$').hasMatch(uri.queryParameters['client_id'] ?? '') &&
      uri.queryParameters['response_type'] == 'code' &&
      RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(state) &&
      RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(codeChallenge) &&
      uri.queryParameters['code_challenge_method'] == 'S256' &&
      scopes.contains('openid') &&
      redirectUri != null &&
      isLoomSubscriptionUrl(redirectUri.toString());
}

String _deviceLabel(String platform, String installationId) {
  final name = switch (platform.toLowerCase()) {
    'android' => 'Android',
    'macos' => 'Mac',
    'windows' => 'Windows PC',
    _ => 'LOOM device',
  };
  return '$name • ${installationId.substring(0, 4).toUpperCase()}';
}

String _sessionCookie(Headers headers) {
  for (final value in headers['set-cookie'] ?? const <String>[]) {
    final match = RegExp(r'(?:^|;\s*)session=([^;]+)').firstMatch(value);
    if (match != null && match.group(1)?.isNotEmpty == true) {
      return match.group(1)!;
    }
  }
  throw const LoomAuthException(LoomAuthFailure.invalidResponse);
}

String _mihomoUrl(String value) {
  if (!isLoomSubscriptionUrl(value)) {
    throw const LoomAuthException(LoomAuthFailure.invalidResponse);
  }
  final uri = Uri.parse(value);
  if (uri.pathSegments.isNotEmpty && uri.pathSegments.last == 'mihomo') {
    return uri.toString();
  }
  final path = '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}mihomo';
  final result = uri.replace(path: path).toString();
  if (!isLoomSubscriptionUrl(result)) {
    throw const LoomAuthException(LoomAuthFailure.invalidResponse);
  }
  return result;
}

LoomAuthException _failure(DioException error) {
  final status = error.response?.statusCode;
  if (status == HttpStatus.tooManyRequests) {
    return const LoomAuthException(LoomAuthFailure.rateLimited);
  }
  if (status == HttpStatus.conflict) {
    return const LoomAuthException(LoomAuthFailure.deviceLimit);
  }
  if (status == HttpStatus.badRequest || status == HttpStatus.notFound) {
    final detail = _errorDetail(error.response?.data);
    return LoomAuthException(
      detail.contains('expired')
          ? LoomAuthFailure.expiredCode
          : LoomAuthFailure.invalidCode,
    );
  }
  if (status == null ||
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout) {
    return const LoomAuthException(LoomAuthFailure.network);
  }
  return const LoomAuthException(LoomAuthFailure.invalidResponse);
}

String _errorDetail(Object? value) {
  try {
    return (_map(value)['detail'] as String? ?? '').toLowerCase();
  } catch (_) {
    return '';
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  throw const LoomAuthException(LoomAuthFailure.invalidResponse);
}
