import 'package:fl_clash/models/clash_config.dart';
import 'package:fl_clash/views/loom.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LOOM diagnostics expose no subscription secret', () {
    const secret = 'https://loomhost.ru/sub/very-secret-token';
    final report = buildLoomDiagnosticReport(
      appVersion: '1.0.0',
      systemName: 'macOS 15.6',
      deviceName: 'MacBook Pro',
      network: 'wifi',
      publicIp: '203.0.113.1',
      countryCode: 'RU',
      vpnState: 'connected',
      coreState: 'connected',
      profileUrl: secret,
      server: 'Frankfurt',
      protocol: 'vless',
      adblockEnabled: true,
      directRoutes: 2,
    );

    expect(report, contains('Support ID:'));
    expect(report, contains('Network: wifi'));
    expect(report, isNot(contains(secret)));
    expect(report, isNot(contains('very-secret-token')));
  });

  test('LOOM adblock is one GEOSITE reject rule', () {
    final rule = createLoomAdblockRule();

    expect(loomAccent.toARGB32(), 0xFFFF3300);
    expect(rule.rawValue, 'GEOSITE,category-ads-all,REJECT');
    expect(isLoomAdblockRule(rule), isTrue);
    expect(isLoomAdblockRule(Rule.parse('GEOSITE,private,DIRECT')), isFalse);
  });

  test('LOOM direct rules normalize safe domain and IP inputs', () {
    expect(
      createLoomDirectRule('https://Sub.Example.com/path')?.rawValue,
      'DOMAIN-SUFFIX,sub.example.com,DIRECT',
    );
    expect(
      createLoomDirectRule('*.Example.com.')?.rawValue,
      'DOMAIN-SUFFIX,example.com,DIRECT',
    );
    expect(
      createLoomDirectRule('192.168.1.1')?.rawValue,
      'IP-CIDR,192.168.1.1/32,DIRECT,no-resolve',
    );
    expect(
      createLoomDirectRule('10.0.0.0/8')?.rawValue,
      'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
    );
    expect(
      createLoomDirectRule('2001:db8::1')?.rawValue,
      'IP-CIDR6,2001:db8::1/128,DIRECT,no-resolve',
    );
    expect(isLoomDirectRule(createLoomDirectRule('example.com')!), isTrue);
  });

  test('LOOM direct rules reject malformed and injectable inputs', () {
    for (final value in [
      '',
      'ftp://example.com',
      'example.com/path',
      'example.com:443',
      'bad domain.com',
      'example.com,DIRECT',
      '10.0.0.0/33',
      '2001:db8::/129',
    ]) {
      expect(createLoomDirectRule(value), isNull, reason: value);
    }
    expect(isLoomDirectRule(Rule.parse('DOMAIN,example.com,REJECT')), isFalse);
  });
}
