import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'loom_device_credential.dart';
import 'loom_support.dart';

const _apiKey = String.fromEnvironment('LOOM_FIREBASE_API_KEY');
const _projectId = String.fromEnvironment('LOOM_FIREBASE_PROJECT_ID');
const _appId = String.fromEnvironment('LOOM_FIREBASE_APP_ID');
const _messagingSenderId = String.fromEnvironment(
  'LOOM_FIREBASE_MESSAGING_SENDER_ID',
);

enum LoomPushRoute { support, subscription }

class LoomPushEvent {
  final LoomPushRoute? route;
  final String? title;
  final String? body;
  final bool opened;

  const LoomPushEvent({
    required this.route,
    required this.title,
    required this.body,
    required this.opened,
  });
}

FirebaseOptions? createLoomFirebaseOptions({
  required String apiKey,
  required String projectId,
  required String appId,
  required String messagingSenderId,
}) {
  final values = [apiKey, projectId, appId, messagingSenderId];
  if (values.any((value) => value.trim().isEmpty || value.length > 256)) {
    return null;
  }
  return FirebaseOptions(
    apiKey: apiKey,
    projectId: projectId,
    appId: appId,
    messagingSenderId: messagingSenderId,
  );
}

LoomPushRoute? parseLoomPushRoute(Map<String, dynamic> data) =>
    switch (data['route']) {
      'support' => LoomPushRoute.support,
      'subscription' => LoomPushRoute.subscription,
      _ => null,
    };

Future<void> registerLoomPushToken({
  required Dio dio,
  required String deviceCredential,
  required String token,
  required String appVersion,
  required String appBuild,
}) async {
  if (!isLoomDeviceCredential(deviceCredential) ||
      token.trim().isEmpty ||
      token.length > 4096) {
    throw const FormatException('invalid push registration');
  }
  await dio.put<Object?>(
    loomSupportApiUri.resolve('/api/v1/device/push-token').toString(),
    data: {
      'provider': 'fcm',
      'token': token,
      'platform': 'android',
      'app_version': appVersion,
      'app_build': appBuild,
    },
    options: Options(
      headers: {'Authorization': 'Bearer $deviceCredential'},
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );
}

class LoomPush {
  final _events = StreamController<LoomPushEvent>.broadcast();
  final Dio _dio;
  final FirebaseOptions? _options;
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  String? _appVersion;
  String? _appBuild;
  bool _ready = false;
  bool _started = false;

  LoomPush({Dio? dio, FirebaseOptions? options})
    : _dio = dio ?? createLoomApiDio(),
      _options =
          options ??
          createLoomFirebaseOptions(
            apiKey: _apiKey,
            projectId: _projectId,
            appId: _appId,
            messagingSenderId: _messagingSenderId,
          );

  Stream<LoomPushEvent> get events => _events.stream;

  bool get configured => Platform.isAndroid && _options != null;

  Future<String?> deviceCredentialForAuth() async =>
      configured ? loomDeviceCredentials.getOrCreate() : null;

  Future<void> bootstrap() async {
    if (!configured || _ready) return;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: _options);
      }
      _ready = true;
    } catch (error) {
      debugPrint('LOOM push initialization failed: $error');
    }
  }

  Future<void> start({
    required String appVersion,
    required String appBuild,
  }) async {
    _appVersion = appVersion;
    _appBuild = appBuild;
    await bootstrap();
    if (!_ready || _started) return;
    try {
      await FirebaseMessaging.instance.requestPermission();
      _tokenSubscription = FirebaseMessaging.instance.onTokenRefresh.listen(
        (token) => unawaited(syncToken(token)),
      );
      _messageSubscription = FirebaseMessaging.onMessage.listen(
        (message) => _emit(message, opened: false),
      );
      _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _emit(message, opened: true),
      );
      _started = true;
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _emit(initial, opened: true);
      await syncToken();
    } catch (error) {
      await stop();
      debugPrint('LOOM push start failed: $error');
    }
  }

  Future<void> syncToken([String? refreshedToken]) async {
    if (!_ready || _appVersion == null || _appBuild == null) return;
    try {
      final credential = await loomDeviceCredentials.current();
      final token =
          refreshedToken ?? await FirebaseMessaging.instance.getToken();
      if (credential == null || token == null) return;
      await registerLoomPushToken(
        dio: _dio,
        deviceCredential: credential,
        token: token,
        appVersion: _appVersion!,
        appBuild: _appBuild!,
      );
    } catch (error) {
      debugPrint('LOOM push token sync failed: $error');
    }
  }

  Future<void> stop() async {
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _openedSubscription?.cancel();
    _tokenSubscription = null;
    _messageSubscription = null;
    _openedSubscription = null;
    _started = false;
  }

  void _emit(RemoteMessage message, {required bool opened}) {
    final notification = message.notification;
    final route = parseLoomPushRoute(message.data);
    if (route == null && notification == null) return;
    _events.add(
      LoomPushEvent(
        route: route,
        title: _safeText(notification?.title, 120),
        body: _safeText(notification?.body, 500),
        opened: opened,
      ),
    );
  }

  String? _safeText(String? value, int maxLength) {
    value = value?.trim();
    if (value == null || value.isEmpty) return null;
    final safe = value.replaceAll(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
      '',
    );
    if (safe.isEmpty) return null;
    return safe.length <= maxLength ? safe : safe.substring(0, maxLength);
  }
}

final loomPush = LoomPush();
