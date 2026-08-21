import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'link.dart';
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

  LoomAuthClient({
    required this.platform,
    required this.appVersion,
    required this.appBuild,
    Dio? dio,
  }) : _dio = dio ?? _createLoomAuthDio();

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

Dio _createLoomAuthDio() {
  final dio = Dio(
    BaseOptions(
      headers: {'Accept': 'application/json'},
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient(
        context: SecurityContext(withTrustedRoots: true),
      );
      client.badCertificateCallback = null;
      client.findProxy = (_) => 'DIRECT';
      return client;
    },
  );
  return dio;
}
