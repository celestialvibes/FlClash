import 'package:fl_clash/common/link.dart';
import 'package:test/test.dart';

void main() {
  test('extracts the URL only from loomhost install-config links', () {
    const profileUrl = 'https://example.com/profile?a=1&b=2';
    final query = Uri.encodeQueryComponent(profileUrl);

    expect(
      LinkManager.extractInstallConfigUrl(
        Uri.parse('loomhost://install-config?url=$query'),
      ),
      profileUrl,
    );
    expect(
      LinkManager.extractInstallConfigUrl(
        Uri.parse('flclash://install-config?url=$query'),
      ),
      isNull,
    );
    expect(
      LinkManager.extractInstallConfigUrl(
        Uri.parse('loomhost://install-config?url=file%3A%2F%2F%2Ftmp%2Fx'),
      ),
      isNull,
    );
  });
}
