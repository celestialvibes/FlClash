import 'dart:io';

import 'proxy_command.dart';

class MacosProxy {
  final ProxyCommandRunner _commandRunner;
  final Map<String, File> _watchdogMarkers = {};
  final Set<String> _configuredServices = {};

  MacosProxy({required ProxyCommandRunner commandRunner})
    : _commandRunner = commandRunner;

  Future<bool> start(int port, List<String> bypassDomain) async {
    final service = await _primaryNetworkService();
    if (service == null) return false;

    final previousServices = _configuredServices.difference({service});
    if (previousServices.isNotEmpty) {
      final stopped = await _commandRunner.run(
        previousServices.expand(MacosProxyCommands.buildStop),
      );
      if (!stopped) return false;
      for (final previousService in previousServices) {
        await _disarmWatchdog(previousService);
      }
      _configuredServices.removeAll(previousServices);
    }

    if (!await _armWatchdog(service, port)) return false;
    final started = await _commandRunner.run(
      MacosProxyCommands.buildStart(service, port, bypassDomain),
    );
    if (!started) {
      final cleaned = await _commandRunner.run(
        MacosProxyCommands.buildStop(service),
      );
      if (cleaned) await _disarmWatchdog(service);
      return false;
    }
    _configuredServices.add(service);
    return true;
  }

  Future<bool> stop() async {
    final services = _configuredServices.isNotEmpty
        ? _configuredServices.toList()
        : await _staleLoomProxyServices();
    if (services.isEmpty) {
      await _disarmWatchdogs();
      return true;
    }
    final stopped = await _commandRunner.run(
      services.expand(MacosProxyCommands.buildStop),
    );
    if (stopped) {
      await _disarmWatchdogs();
      _configuredServices.clear();
    }
    return stopped;
  }

  Future<String?> _primaryNetworkService() async {
    try {
      final route = await _commandRunner.process('/sbin/route', [
        '-n',
        'get',
        'default',
      ]);
      final services = await _commandRunner.process('/usr/sbin/networksetup', [
        '-listnetworkserviceorder',
      ]);
      if (route.exitCode != 0 || services.exitCode != 0) return null;
      return MacosProxyCommands.parsePrimaryNetworkService(
        route.stdout.toString(),
        services.stdout.toString(),
      );
    } on ProcessException {
      return null;
    }
  }

  Future<List<String>> _staleLoomProxyServices() async {
    final service = await _primaryNetworkService();
    if (service == null) return const [];
    try {
      final results = await Future.wait(
        ['-getwebproxy', '-getsecurewebproxy', '-getsocksfirewallproxy'].map(
          (command) => _commandRunner.process('/usr/sbin/networksetup', [
            command,
            service,
          ]),
        ),
      );
      if (results.any((result) => result.exitCode != 0)) return const [];
      return MacosProxyCommands.isLoomProxy(
            results.map((result) => result.stdout.toString()),
          )
          ? [service]
          : const [];
    } on ProcessException {
      return const [];
    }
  }

  Future<bool> _armWatchdog(String service, int port) async {
    final currentMarker = _watchdogMarkers[service];
    final marker = File(
      '${Directory.systemTemp.path}/loom-proxy-$pid-${service.hashCode}.active',
    );
    try {
      if (currentMarker != null) {
        final currentPort = await currentMarker.readAsString();
        if (currentPort == '$port') return true;
        await _disarmWatchdog(service);
      }
      await marker.writeAsString('$port');
      await Process.start(
        '/bin/sh',
        MacosProxyCommands.buildWatchdogArguments(
          parentPid: pid,
          markerPath: marker.path,
          service: service,
          port: port,
        ),
        mode: ProcessStartMode.detached,
      );
      _watchdogMarkers[service] = marker;
      return true;
    } on FileSystemException {
      return false;
    } on ProcessException {
      if (await marker.exists()) await marker.delete();
      return false;
    }
  }

  Future<void> _disarmWatchdog(String service) async {
    final marker = _watchdogMarkers.remove(service);
    if (marker != null && await marker.exists()) await marker.delete();
  }

  Future<void> _disarmWatchdogs() async {
    for (final service in _watchdogMarkers.keys.toList()) {
      await _disarmWatchdog(service);
    }
  }
}

class MacosProxyCommands {
  static const watchdogScript = r'''
parent_pid="$1"
marker="$2"
service="$3"
port="$4"
while kill -0 "$parent_pid" 2>/dev/null; do sleep 1; done
[ -f "$marker" ] || exit 0
owned=0
disable_if_owned() {
  output=$(/usr/sbin/networksetup "$1" "$service" 2>/dev/null) || return
  printf '%s\n' "$output" | /usr/bin/grep -Fq 'Server: 127.0.0.1' || return
  printf '%s\n' "$output" | /usr/bin/grep -Fq "Port: $port" || return
  /usr/sbin/networksetup "$2" "$service" off
  owned=1
}
disable_if_owned -getwebproxy -setwebproxystate
disable_if_owned -getsecurewebproxy -setsecurewebproxystate
disable_if_owned -getsocksfirewallproxy -setsocksfirewallproxystate
if [ "$owned" -eq 1 ]; then
  /usr/sbin/networksetup -setproxybypassdomains "$service" Empty
fi
/bin/rm -f "$marker"
''';

  static List<String> buildWatchdogArguments({
    required int parentPid,
    required String markerPath,
    required String service,
    required int port,
  }) {
    return [
      '-c',
      watchdogScript,
      'loom-proxy-watchdog',
      '$parentPid',
      markerPath,
      service,
      '$port',
    ];
  }

  static String? parsePrimaryNetworkService(
    String routeOutput,
    String serviceOrderOutput,
  ) {
    final interface = RegExp(
      r'^\s*interface:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(routeOutput)?.group(1);
    if (interface == null) return null;

    final lines = serviceOrderOutput.split('\n');
    for (var index = 0; index + 1 < lines.length; index++) {
      final service = RegExp(r'^\(\d+\)\s+(.+)$').firstMatch(lines[index]);
      if (service == null) continue;
      final device = RegExp(
        r'Device:\s*([^\)]+)\)',
      ).firstMatch(lines[index + 1])?.group(1)?.trim();
      if (device == interface) return service.group(1)?.trim();
    }
    return null;
  }

  static bool isLoomProxy(Iterable<String> proxyOutputs) {
    final outputs = proxyOutputs.toList();
    if (outputs.length != 3) return false;
    int? port;
    for (final output in outputs) {
      if (!output.contains('Enabled: Yes') ||
          !output.contains('Server: $proxyHost')) {
        return false;
      }
      final currentPort = int.tryParse(
        RegExp(
              r'^Port:\s*(\d+)\s*$',
              multiLine: true,
            ).firstMatch(output)?.group(1) ??
            '',
      );
      if (currentPort == null || (port != null && currentPort != port)) {
        return false;
      }
      port = currentPort;
    }
    return true;
  }

  static List<ProxyCommand> buildStart(
    String service,
    int port,
    List<String> bypassDomain,
  ) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxy',
        service,
        proxyHost,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxy',
        service,
        proxyHost,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxy',
        service,
        proxyHost,
        '$port',
      ]),
      buildProxyBypass(service, bypassDomain),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxystate',
        service,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        service,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        service,
        'on',
      ]),
    ];
  }

  static List<ProxyCommand> buildStop(String service) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        service,
        'off',
      ]),
      buildProxyBypass(service, const []),
    ];
  }

  static ProxyCommand buildProxyBypass(
    String service,
    List<String> bypassDomain,
  ) {
    return ProxyCommand('/usr/sbin/networksetup', [
      '-setproxybypassdomains',
      service,
      if (bypassDomain.isEmpty) 'Empty' else ...bypassDomain,
    ]);
  }
}
