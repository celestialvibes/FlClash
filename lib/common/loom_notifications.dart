import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'preferences.dart';
import 'system.dart';

const _enabledKey = 'loomExpiryNotificationsV1';
const _reminderDays = [3, 1];

List<(int, DateTime)> loomExpiryReminderTimes(
  DateTime expiresAt,
  DateTime now,
) => _reminderDays
    .map((days) => (days, expiresAt.subtract(Duration(days: days))))
    .where((reminder) => reminder.$2.isAfter(now))
    .toList();

class LoomExpiryNotifications extends ValueNotifier<bool> {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  LoomExpiryNotifications() : super(false);

  bool get _supported => system.isAndroid || system.isMacOS || system.isWindows;

  Future<void> initialize() async {
    if (_ready) return;
    value = await preferences.getString(_enabledKey) == 'true';
    if (!_supported) return;
    try {
      tz.initializeTimeZones();
      _ready =
          await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('ic'),
              macOS: DarwinInitializationSettings(
                requestAlertPermission: false,
                requestBadgePermission: false,
                requestSoundPermission: false,
              ),
              windows: WindowsInitializationSettings(
                appName: 'LOOM',
                appUserModelId: 'LOOM.VPN.Client',
                guid: '473702EA-6B91-47EE-AF3E-0AB23EAC33F1',
              ),
            ),
          ) ??
          false;
    } catch (error) {
      debugPrint('LOOM notification initialization failed: $error');
    }
  }

  Future<bool> setEnabled(bool enabled, int? expiresAtSeconds) async {
    await initialize();
    if (!_ready) return false;
    if (enabled && !await _requestPermission()) return false;
    if (!await preferences.setString(_enabledKey, enabled.toString())) {
      return false;
    }
    value = enabled;
    await sync(expiresAtSeconds);
    return true;
  }

  Future<void> sync(int? expiresAtSeconds) async {
    await initialize();
    if (!_ready) return;
    for (final days in _reminderDays) {
      await _plugin.cancel(id: _notificationId(days));
    }
    if (!value) return;
    final expiresAt = _expiresAt(expiresAtSeconds);
    if (expiresAt == null) return;
    for (final reminder in loomExpiryReminderTimes(expiresAt, DateTime.now())) {
      await _plugin.zonedSchedule(
        id: _notificationId(reminder.$1),
        title: 'Подписка скоро закончится',
        body: reminder.$1 == 1
            ? 'Остался 1 день. Продлите LOOM без перерыва.'
            : 'Осталось ${reminder.$1} дня. Продлите LOOM без перерыва.',
        scheduledDate: tz.TZDateTime.from(reminder.$2.toUtc(), tz.UTC),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'loom_subscription',
            'Подписка LOOM',
            channelDescription: 'Напоминания об окончании подписки',
          ),
          macOS: DarwinNotificationDetails(
            threadIdentifier: 'loom_subscription',
          ),
          windows: WindowsNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'subscription',
      );
    }
  }

  Future<bool> _requestPermission() async {
    if (system.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (system.isMacOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: false, sound: true) ??
          false;
    }
    return true;
  }

  DateTime? _expiresAt(int? seconds) {
    seconds ??= 0;
    return seconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000)
        : null;
  }

  int _notificationId(int days) => 21000 + days;
}

final loomExpiryNotifications = LoomExpiryNotifications();
