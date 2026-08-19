import 'package:fl_clash/common/loom_support.dart';
import 'package:fl_clash/views/loom.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('support badge appears for a new operator message', (
    tester,
  ) async {
    loomSupportInbox.restore('test-support', 0);
    addTearDown(() => loomSupportInbox.restore('test-cleanup', 0));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LoomSupportUnreadBadge(child: Icon(Icons.settings_outlined)),
        ),
      ),
    );

    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);

    loomSupportInbox.merge('test-support', [
      LoomSupportMessage.fromJson({
        'id': 1,
        'sender_kind': 'admin',
        'kind': 'text',
        'text': 'Ответ оператора',
        'created_at': '2026-08-19T00:00:00Z',
      }),
    ]);
    await tester.pump();

    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);
  });
}
