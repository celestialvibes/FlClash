import 'dart:convert';

import 'package:fl_clash/common/loom_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('support endpoint is one exact HTTPS origin', () {
    expect(loomSupportApiUri.scheme, 'https');
    expect(loomSupportApiUri.origin, loomSupportApiBaseUrl);
    expect(loomSupportApiHost, isNotEmpty);
  });

  test('client only accepts allowlisted typed operator actions', () {
    LoomSupportMessage action(String kind, Map<String, Object?> payload) {
      return LoomSupportMessage.fromJson({
        'id': 1,
        'sender_kind': 'admin',
        'kind': 'action',
        'text': '',
        'action_kind': kind,
        'action_payload': payload,
        'action_state': 'pending',
        'action_expires_at': '2099-01-01T00:00:00Z',
        'created_at': '2026-08-19T00:00:00Z',
      });
    }

    expect(
      action('choice_v1', {
        'prompt': 'Повторить?',
        'choices': [
          {'id': 'yes', 'label': 'Да'},
          {'id': 'no', 'label': 'Нет'},
        ],
      }).isSupportedAction,
      isTrue,
    );
    expect(
      action('request_diagnostics_v1', const {}).isSupportedAction,
      isTrue,
    );
    for (final kind in [
      'request_diagnostics_v2',
      'detect_network_conflicts_v1',
      'replace_subscription_v1',
    ]) {
      expect(action(kind, const {}).isSupportedAction, isTrue, reason: kind);
    }
    expect(
      action('request_diagnostics_v1', {
        'url': 'https://example.invalid',
      }).isSupportedAction,
      isFalse,
    );
    expect(
      action('open_screen_v1', {'screen': 'support'}).isSupportedAction,
      isTrue,
    );
    expect(
      action('open_screen_v1', {'screen': 'billing'}).isSupportedAction,
      isFalse,
    );
    expect(action('shell_v1', {'command': 'id'}).isSupportedAction, isFalse);
  });

  test('service events and network context are strictly parsed', () {
    final event = LoomSupportMessage.fromJson({
      'id': 2,
      'sender_kind': 'admin',
      'kind': 'event',
      'text': '',
      'event_kind': 'days_added_v1',
      'event_payload': {'expires_on': '2026-08-31'},
      'created_at': '2026-08-19T00:00:00Z',
    });
    expect(event.isSupportedEvent, isTrue);
    expect(
      LoomSupportNetworkContext.fromJson({
        'public_ip': '203.0.113.1',
        'country_code': 'RU',
        'asn': 'AS12345',
        'operator': 'Example ISP',
      }).operatorName,
      'Example ISP',
    );
    expect(
      () => LoomSupportNetworkContext.fromJson({'public_ip': 'not-an-ip'}),
      throwsFormatException,
    );
  });

  test('support read cursor is scoped to its installation', () {
    final stored = jsonEncode({
      'support_id': 'support-a',
      'last_seen_message_id': 42,
    });

    expect(parseLoomSupportLastSeenMessageId(stored, 'support-a'), 42);
    expect(parseLoomSupportLastSeenMessageId(stored, 'support-b'), 0);
    expect(parseLoomSupportLastSeenMessageId('invalid', 'support-a'), 0);
    expect(
      parseLoomSupportLastSeenMessageId(
        jsonEncode({'support_id': 'support-a', 'last_seen_message_id': -1}),
        'support-a',
      ),
      0,
    );
  });

  test('inbox only marks unseen operator messages unread', () async {
    LoomSupportMessage message(int id, String senderKind) {
      return LoomSupportMessage.fromJson({
        'id': id,
        'sender_kind': senderKind,
        'kind': 'text',
        'text': 'message',
        'created_at': '2026-08-19T00:00:00Z',
      });
    }

    final inbox = LoomSupportInbox()..restore('support-a', 10);
    inbox.merge('support-a', [message(11, 'client')]);
    expect(inbox.value, isFalse);

    inbox.merge('support-a', [message(10, 'admin'), message(12, 'admin')]);
    expect(inbox.value, isTrue);
    expect(inbox.afterId, 12);

    await inbox.markSeenThrough('support-a', 12);
    expect(inbox.value, isFalse);

    inbox.restore('support-b', 0);
    expect(inbox.value, isFalse);
  });
}
