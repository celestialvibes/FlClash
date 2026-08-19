import 'dart:io';

import 'package:fl_clash/common/loom_diagnostics.dart';
import 'package:fl_clash/common/loom_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostics v2 sanitize lines and only add consented network data', () {
    final report = buildLoomDiagnosticReportV2(
      appVersion: '0.2.0',
      appBuild: '15',
      platform: 'macos',
      osVersion: 'macOS 15.6\nInjected: value',
      architecture: 'arm64',
      coreName: 'mihomo',
      coreVersion: '1.19.0',
      vpnConnected: true,
      coreStatus: 'connected',
      mode: 'rule',
      tunEnabled: true,
      systemProxyEnabled: false,
      serverName: 'Frankfurt\nFake: field',
      proxyType: 'vless',
      pingMs: 21,
      uptimeMs: 42000,
      subscriptionUpdatedAt: DateTime.utc(2026, 8, 19),
      subscriptionExpiresAt: DateTime.utc(2026, 8, 31),
      subscriptionUsedBytes: 100,
      subscriptionTotalBytes: 1000,
      adblockEnabled: true,
      directRules: 2,
      lastNetworkFailureAt: '2026-08-19 12:00:00',
      connectivity: 'wifi',
    );

    expect(report, contains('Server: Frankfurt Fake: field'));
    expect(report, contains('Subscription total bytes: 1000'));
    expect(report, isNot(contains('Public IP:')));

    final withNetwork = buildLoomDiagnosticReportV2(
      appVersion: '0.2.0',
      appBuild: '15',
      platform: 'macos',
      osVersion: 'macOS',
      architecture: 'arm64',
      coreName: 'mihomo',
      coreVersion: '1.19.0',
      vpnConnected: true,
      coreStatus: 'connected',
      mode: 'rule',
      tunEnabled: true,
      systemProxyEnabled: false,
      serverName: 'Frankfurt',
      proxyType: 'vless',
      pingMs: 21,
      uptimeMs: 42000,
      subscriptionUpdatedAt: null,
      subscriptionExpiresAt: null,
      subscriptionUsedBytes: null,
      subscriptionTotalBytes: null,
      adblockEnabled: false,
      directRules: 0,
      lastNetworkFailureAt: null,
      connectivity: 'wifi',
      network: const LoomSupportNetworkContext(
        publicIp: '203.0.113.1',
        countryCode: 'RU',
        asn: 'AS123',
        operatorName: 'Example ISP',
      ),
    );
    expect(withNetwork, contains('Public IP: 203.0.113.1'));
    expect(withNetwork, contains('Operator: Example ISP'));
  });

  test(
    'macOS conflict scan reports VPN, routes, proxies, DNS, and stale port',
    () async {
      Future<ProcessResult> runner(
        String executable,
        List<String> arguments,
      ) async {
        final key = '$executable ${arguments.join(' ')}';
        final output = switch (key) {
          '/usr/sbin/scutil --nc list' =>
            '* (Connected) id VPN (io.tailscale) "Tailscale" [VPN]',
          '/sbin/ifconfig -l' => 'lo0 en0 utun3 utun4',
          '/sbin/route -n get default' =>
            'gateway: 192.168.1.1\ninterface: en0\n',
          '/usr/sbin/networksetup -listallnetworkservices' =>
            'An asterisk denotes disabled.\nWi-Fi\n',
          '/usr/sbin/networksetup -getwebproxy Wi-Fi' =>
            'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n',
          '/usr/sbin/networksetup -getdnsservers Wi-Fi' => '1.1.1.1\n8.8.8.8\n',
          _ => '',
        };
        return ProcessResult(1, 0, output, '');
      }

      final report = await detectLoomNetworkConflicts(
        loomConnected: false,
        runner: runner,
      );
      expect(report, contains('Connected VPN services: Tailscale'));
      expect(report, contains('utun3, utun4'));
      expect(report, contains('Default route: en0 via 192.168.1.1'));
      expect(report, contains('Wi-Fi HTTP 127.0.0.1:7890'));
      expect(report, contains('Stale LOOM proxy 127.0.0.1:7890: yes'));
      expect(report, contains('Wi-Fi=1.1.1.1,8.8.8.8'));
    },
  );
}
