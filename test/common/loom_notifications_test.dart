import 'package:fl_clash/common/loom_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expiry reminders keep only future thresholds', () {
    final now = DateTime.utc(2026, 8, 21, 12);
    final expiry = DateTime.utc(2026, 8, 23, 12);

    expect(loomExpiryReminderTimes(expiry, now), [
      (1, DateTime.utc(2026, 8, 22, 12)),
    ]);
  });
}
