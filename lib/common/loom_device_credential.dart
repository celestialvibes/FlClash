import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _credentialKey = 'loomDeviceCredentialV1';
final _credentialPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

bool isLoomDeviceCredential(String? value) =>
    value != null && _credentialPattern.hasMatch(value);

String generateLoomDeviceCredential([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => source.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

class LoomDeviceCredentials {
  final FlutterSecureStorage _storage;

  const LoomDeviceCredentials({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  Future<String?> current() async {
    final value = await _storage.read(key: _credentialKey);
    return isLoomDeviceCredential(value) ? value : null;
  }

  Future<String> getOrCreate() async {
    final currentValue = await current();
    if (currentValue != null) return currentValue;
    final value = generateLoomDeviceCredential();
    await _storage.write(key: _credentialKey, value: value);
    return value;
  }
}

const loomDeviceCredentials = LoomDeviceCredentials();
