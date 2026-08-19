import 'package:fl_clash/models/clash_config.dart';
import 'package:fl_clash/common/loom_support.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/loom.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LOOM diagnostics only expose coarse allowlisted state', () {
    final report = buildLoomSafeDiagnosticReport(
      appVersion: 'secret build value',
      platform: 'MacBook Pro secret model',
      vpnConnected: true,
      coreStatus: CoreStatus.connected,
      proxyType: 'Frankfurt secret server',
      proxySelection: LoomDiagnosticProxySelection.named,
      subscriptionPresent: true,
      subscriptionFreshness: LoomDiagnosticFreshness.fresh,
      subscriptionExpiry: LoomDiagnosticExpiry.later,
      subscriptionQuota: LoomDiagnosticQuota.available,
      connectivity: LoomDiagnosticConnectivity.wifi,
    );

    expect(report, contains('App version: unknown'));
    expect(report, contains('Platform: other'));
    expect(report, contains('Proxy type: other'));
    expect(report, contains('Connectivity: wifi'));
    for (final forbidden in [
      'secret build value',
      'MacBook Pro secret model',
      'Frankfurt secret server',
      '203.0.113.1',
      'very-secret-token',
      'https://loomhost.ru/sub/',
      'Public IP',
      'Support ID',
    ]) {
      expect(report, isNot(contains(forbidden)), reason: forbidden);
    }
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
    final supportRule = createLoomSupportDirectRule();
    expect(supportRule.rawValue, 'DOMAIN-SUFFIX,$loomSupportApiHost,DIRECT');
    expect(isLoomSupportDirectRule(supportRule), isTrue);
    expect(isLoomDirectRule(supportRule), isFalse);
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
