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
}
