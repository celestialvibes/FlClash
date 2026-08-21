import 'package:fl_clash/common/link.dart';
import 'package:test/test.dart';

void main() {
  test('extracts only allowed LOOM subscriptions from loomvpn add links', () {
    const profileUrl = 'https://lmvn.pro/Ab3dE/mihomo';
    final query = Uri.encodeQueryComponent(profileUrl);

    expect(
      LinkManager.extractAddUrl(
        Uri.parse('loomvpn://add?url=$query'),
      ),
      profileUrl,
    );
    expect(
      LinkManager.extractAddUrl(
        Uri.parse('loomhost://install-config?url=$query'),
      ),
      isNull,
    );
    expect(
      LinkManager.extractAddUrl(
        Uri.parse('loomvpn://add?url=https%3A%2F%2Fevil.example%2Fsub'),
      ),
      isNull,
    );
  });

  test('allows only HTTPS URLs on LOOM-owned hosts', () {
    expect(isLoomSubscriptionUrl('https://lmvn.pro/Ab3dE/mihomo'), isTrue);
    expect(isLoomSubscriptionUrl('https://api.loomvpn.pro/config/token'), isTrue);
    expect(isLoomSubscriptionUrl('https://loomhost.ru/sub/token'), isTrue);
    expect(isLoomSubscriptionUrl('http://lmvn.pro/Ab3dE'), isFalse);
    expect(isLoomSubscriptionUrl('https://lmvn.pro.evil.example/sub'), isFalse);
    expect(isLoomSubscriptionUrl('https://evil.example/sub'), isFalse);
  });
}
