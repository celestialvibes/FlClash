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
    switch (data['cta'] ?? data['route']) {
      'support' => LoomPushRoute.support,
      'plans' || 'subscription' => LoomPushRoute.subscription,
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
  int _generation = 0;

  @protected
  Future<FirebaseMessaging?> messagingForStart() async {
    await bootstrap();
    return _ready ? FirebaseMessaging.instance : null;
  }

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
    if (_started) return;
    _started = true;
    final generation = ++_generation;
    _appVersion = appVersion;
    _appBuild = appBuild;
    try {
      final messaging = await messagingForStart();
      if (generation != _generation) return;
      if (messaging == null) {
        _started = false;
        return;
      }
      await messaging.requestPermission();
      if (generation != _generation) return;
      _tokenSubscription = messaging.onTokenRefresh.listen(
        (token) => unawaited(syncToken(token)),
      );
      _messageSubscription = FirebaseMessaging.onMessage.listen(
        (message) => _emit(message, opened: false),
      );
      _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _emit(message, opened: true),
      );
      final initial = await messaging.getInitialMessage();
      if (generation != _generation) return;
      if (initial != null) _emit(initial, opened: true);
      await syncToken();
    } catch (error) {
      if (generation == _generation) await stop();
      debugPrint('LOOM push start failed: $error');
    }
  }

  Future<void> syncToken([String? refreshedToken]) async {
    if (!_started || !_ready || _appVersion == null || _appBuild == null) {
      return;
    }
    final generation = _generation;
    try {
      final credential = await loomDeviceCredentials.current();
      final token =
          refreshedToken ?? await FirebaseMessaging.instance.getToken();
      if (generation != _generation || credential == null || token == null) {
        return;
      }
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
    _generation++;
    _started = false;
    final subscriptions = [
      _tokenSubscription,
      _messageSubscription,
      _openedSubscription,
    ];
    _tokenSubscription = null;
    _messageSubscription = null;
    _openedSubscription = null;
    await Future.wait([
      for (final subscription in subscriptions)
        if (subscription != null) subscription.cancel(),
    ]);
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
