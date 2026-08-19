import 'dart:async';
import 'dart:io';

import 'loom_support.dart';

typedef LoomProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

String buildLoomDiagnosticReportV2({
  required String appVersion,
  required String appBuild,
  required String platform,
  required String osVersion,
  required String architecture,
  required String coreName,
  required String coreVersion,
  required bool vpnConnected,
  required String coreStatus,
  required String mode,
  required bool tunEnabled,
  required bool systemProxyEnabled,
  required String? serverName,
  required String? proxyType,
  required int? pingMs,
  required int? uptimeMs,
  required DateTime? subscriptionUpdatedAt,
  required DateTime? subscriptionExpiresAt,
  required int? subscriptionUsedBytes,
  required int? subscriptionTotalBytes,
  required bool adblockEnabled,
  required int directRules,
  required String? lastNetworkFailureAt,
  required String connectivity,
  LoomSupportNetworkContext? network,
}) {
  String date(DateTime? value) => value?.toUtc().toIso8601String() ?? 'unknown';
  String value(String? input, {int max = 160}) {
    final sanitized = input
        ?.replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (sanitized == null || sanitized.isEmpty) return 'unknown';
    return sanitized.length <= max ? sanitized : sanitized.substring(0, max);
  }

  return [
    'LOOM diagnostics v2',
    'App: ${value(appVersion, max: 48)} (${value(appBuild, max: 32)})',
    'Platform: ${value(platform, max: 24)}',
    'OS: ${value(osVersion)}',
    'Architecture: ${value(architecture, max: 32)}',
    'Core: ${value(coreName, max: 48)} ${value(coreVersion, max: 64)}',
    'VPN: ${vpnConnected ? 'connected' : 'disconnected'}',
    'Core status: ${value(coreStatus, max: 32)}',
    'Mode: ${value(mode, max: 24)}',
    'TUN: ${tunEnabled ? 'enabled' : 'disabled'}',
    'System proxy: ${systemProxyEnabled ? 'enabled' : 'disabled'}',
    'Server: ${value(serverName)}',
    'Protocol: ${value(proxyType, max: 32)}',
    'Ping: ${pingMs == null ? 'unknown' : '$pingMs ms'}',
    'Uptime: ${uptimeMs == null ? 'unknown' : '${uptimeMs ~/ 1000} s'}',
    'Subscription updated: ${date(subscriptionUpdatedAt)}',
    'Subscription expires: ${date(subscriptionExpiresAt)}',
    'Subscription used bytes: ${subscriptionUsedBytes ?? 'unknown'}',
    'Subscription total bytes: ${subscriptionTotalBytes ?? 'unknown'}',
    'Adblock: ${adblockEnabled ? 'enabled' : 'disabled'}',
    'DIRECT rules: $directRules',
    'Last network failure: ${value(lastNetworkFailureAt, max: 40)}',
    'Connectivity: ${value(connectivity, max: 32)}',
    if (network != null) ...[
      'Public IP: ${value(network.publicIp, max: 45)}',
      'Country: ${value(network.countryCode, max: 2)}',
      'ASN: ${value(network.asn, max: 32)}',
      'Operator: ${value(network.operatorName, max: 120)}',
    ],
  ].join('\n');
}

Future<String> detectLoomNetworkConflicts({
  required bool loomConnected,
  LoomProcessRunner? runner,
}) => _detectLoomNetworkConflicts(
  loomConnected: loomConnected,
  runner: runner,
).timeout(
  const Duration(seconds: 15),
  onTimeout: () =>
      'LOOM network conflicts\nScan timed out; no settings were changed',
);

Future<String> _detectLoomNetworkConflicts({
  required bool loomConnected,
  LoomProcessRunner? runner,
}) async {
  if (!Platform.isMacOS && runner == null) {
    return 'LOOM network conflicts\nPlatform scan is unavailable';
  }
  final run = runner ?? _runProcess;
  final vpnOutput = await _output(run, '/usr/sbin/scutil', ['--nc', 'list']);
  final interfaces = await _output(run, '/sbin/ifconfig', ['-l']);
  final route = await _output(run, '/sbin/route', ['-n', 'get', 'default']);
  final serviceOutput = await _output(run, '/usr/sbin/networksetup', [
    '-listallnetworkservices',
  ]);
  final vpnNames = RegExp(r'\(Connected\).*?"([^"]+)"')
      .allMatches(vpnOutput)
      .map((match) => _clean(match.group(1)))
      .whereType<String>()
      .toList();
  final utuns = interfaces
      .split(RegExp(r'\s+'))
      .where((name) => RegExp(r'^utun\d+$').hasMatch(name))
      .toList();
  final routeInterface = RegExp(
    r'^\s*interface:\s*(\S+)',
    multiLine: true,
  ).firstMatch(route)?.group(1);
  final gateway = RegExp(
    r'^\s*gateway:\s*(\S+)',
    multiLine: true,
  ).firstMatch(route)?.group(1);
  final services = serviceOutput
      .split('\n')
      .skip(1)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('*'))
      .take(20);
  final proxies = <String>[];
  final dns = <String>[];
  var staleLoomProxy = false;
  for (final service in services) {
    for (final type in const {
      'HTTP': '-getwebproxy',
      'HTTPS': '-getsecurewebproxy',
      'SOCKS': '-getsocksfirewallproxy',
    }.entries) {
      final output = await _output(run, '/usr/sbin/networksetup', [
        type.value,
        service,
      ]);
      if (!RegExp(r'^Enabled:\s*Yes$', multiLine: true).hasMatch(output)) {
        continue;
      }
      final server = RegExp(
        r'^Server:\s*(\S+)',
        multiLine: true,
      ).firstMatch(output)?.group(1);
      final port = RegExp(
        r'^Port:\s*(\d+)',
        multiLine: true,
      ).firstMatch(output)?.group(1);
      if (server == null || port == null) continue;
      proxies.add('${_clean(service)} ${type.key} ${_clean(server)}:$port');
      staleLoomProxy |=
          !loomConnected && server == '127.0.0.1' && port == '7890';
    }
    final output = await _output(run, '/usr/sbin/networksetup', [
      '-getdnsservers',
      service,
    ]);
    final servers = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => InternetAddress.tryParse(line) != null)
        .toList();
    if (servers.isNotEmpty) dns.add('${_clean(service)}=${servers.join(',')}');
  }
  final report = [
    'LOOM network conflicts',
    'Connected VPN services: ${vpnNames.isEmpty ? 'none' : vpnNames.join(', ')}',
    'utun interfaces: ${utuns.isEmpty ? 'none' : utuns.join(', ')}',
    'Default route: ${_clean(routeInterface) ?? 'unknown'} via ${_clean(gateway) ?? 'unknown'}',
    'Enabled proxies: ${proxies.isEmpty ? 'none' : proxies.join('; ')}',
    'Stale LOOM proxy 127.0.0.1:7890: ${staleLoomProxy ? 'yes' : 'no'}',
    'DNS: ${dns.isEmpty ? 'automatic/unknown' : dns.join('; ')}',
  ].join('\n');
  return report.length <= 4096 ? report : report.substring(0, 4096);
}

Future<ProcessResult> _runProcess(String executable, List<String> arguments) =>
    Process.run(executable, arguments).timeout(const Duration(seconds: 3));

Future<String> _output(
  LoomProcessRunner run,
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await run(executable, arguments);
    return result.exitCode == 0 ? result.stdout.toString() : '';
  } catch (_) {
    return '';
  }
}

String? _clean(String? value) {
  final clean = value
      ?.replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean == null || clean.isEmpty) return null;
  return clean.length <= 160 ? clean : clean.substring(0, 160);
}
