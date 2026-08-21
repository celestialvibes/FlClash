import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/loom_auth.dart';
import 'package:fl_clash/common/loom_diagnostics.dart';
import 'package:fl_clash/common/loom_support.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/access.dart';
import 'package:fl_clash/views/proxies/common.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

const loomAccent = Color(0xFFFF3300);
const loomBackground = Color(0xFF090909);
const loomSurface = Color(0xFF111111);
const loomSurfaceRaised = Color(0xFF1A1A1A);
const loomInk = Color(0xFFF5F5F2);
const loomMuted = Color(0xFF8A8A86);
const loomBorder = Color(0xFF30302D);
const loomSuccess = Color(0xFF6CF39A);

const loomSubscriptionUrl = 'https://loomvpn.pro';
const loomGuideUrl = 'https://loomhost.ru/start';
const loomAdblockGeosite = 'category-ads-all';

enum LoomDiagnosticProxySelection { none, direct, automatic, named }

enum LoomDiagnosticConnectivity { offline, wifi, mobile, wired, vpn, other }

enum LoomDiagnosticFreshness { unknown, fresh, stale }

enum LoomDiagnosticExpiry { unknown, expired, soon, month, later }

enum LoomDiagnosticQuota { unknown, exhausted, low, available }

String buildLoomSafeDiagnosticReport({
  required String appVersion,
  required String platform,
  required bool vpnConnected,
  required CoreStatus coreStatus,
  required String? proxyType,
  required LoomDiagnosticProxySelection proxySelection,
  required bool subscriptionPresent,
  required LoomDiagnosticFreshness subscriptionFreshness,
  required LoomDiagnosticExpiry subscriptionExpiry,
  required LoomDiagnosticQuota subscriptionQuota,
  required LoomDiagnosticConnectivity connectivity,
}) {
  final safeVersion =
      RegExp(
        r'^[0-9]+(?:\.[0-9]+){1,3}(?:-[0-9A-Za-z.]+)?(?:\+[0-9A-Za-z.]+)?$',
      ).hasMatch(appVersion)
      ? appVersion
      : 'unknown';
  final safePlatform = switch (platform.toLowerCase()) {
    'macos' => 'macos',
    'android' => 'android',
    _ => 'other',
  };
  final safeProxyType = switch (proxyType?.toLowerCase()) {
    'direct' => 'direct',
    'reject' => 'reject',
    'ss' || 'shadowsocks' => 'shadowsocks',
    'ssr' => 'shadowsocksr',
    'vmess' => 'vmess',
    'vless' => 'vless',
    'trojan' => 'trojan',
    'wireguard' => 'wireguard',
    'hysteria' => 'hysteria',
    'hysteria2' => 'hysteria2',
    'tuic' => 'tuic',
    'snell' => 'snell',
    'ssh' => 'ssh',
    'anytls' => 'anytls',
    _ => 'other',
  };
  return [
    'LOOM diagnostics',
    'App version: $safeVersion',
    'Platform: $safePlatform',
    'VPN: ${vpnConnected ? 'connected' : 'disconnected'}',
    'Core: ${coreStatus.name}',
    'Proxy type: $safeProxyType',
    'Proxy selection: ${proxySelection.name}',
    'Subscription: ${subscriptionPresent ? 'present' : 'missing'}',
    'Subscription freshness: ${subscriptionFreshness.name}',
    'Subscription expiry: ${subscriptionExpiry.name}',
    'Subscription quota: ${subscriptionQuota.name}',
    'Connectivity: ${connectivity.name}',
  ].join('\n');
}

LoomDiagnosticConnectivity _loomConnectivity(
  Iterable<ConnectivityResult> values,
) {
  if (values.isEmpty ||
      values.every((value) => value == ConnectivityResult.none)) {
    return LoomDiagnosticConnectivity.offline;
  }
  if (values.contains(ConnectivityResult.wifi)) {
    return LoomDiagnosticConnectivity.wifi;
  }
  if (values.contains(ConnectivityResult.mobile) ||
      values.contains(ConnectivityResult.satellite)) {
    return LoomDiagnosticConnectivity.mobile;
  }
  if (values.contains(ConnectivityResult.ethernet)) {
    return LoomDiagnosticConnectivity.wired;
  }
  if (values.contains(ConnectivityResult.vpn)) {
    return LoomDiagnosticConnectivity.vpn;
  }
  return LoomDiagnosticConnectivity.other;
}

LoomDiagnosticProxySelection _loomProxySelection(Proxy? proxy, Group? group) {
  if (proxy == null) return LoomDiagnosticProxySelection.none;
  if (proxy.name.toUpperCase() == UsedProxy.DIRECT.name ||
      proxy.type.toLowerCase() == 'direct') {
    return LoomDiagnosticProxySelection.direct;
  }
  if (group != null && group.type != GroupType.Selector) {
    return LoomDiagnosticProxySelection.automatic;
  }
  return LoomDiagnosticProxySelection.named;
}

LoomDiagnosticFreshness _loomSubscriptionFreshness(Profile? profile) {
  final updated = profile?.lastUpdateDate;
  if (updated == null) return LoomDiagnosticFreshness.unknown;
  final age = DateTime.now().difference(updated);
  if (age.isNegative) return LoomDiagnosticFreshness.unknown;
  return age <= const Duration(days: 2)
      ? LoomDiagnosticFreshness.fresh
      : LoomDiagnosticFreshness.stale;
}

LoomDiagnosticExpiry _loomSubscriptionExpiry(Profile? profile) {
  final expire = profile?.subscriptionInfo?.expire ?? 0;
  if (expire <= 0) return LoomDiagnosticExpiry.unknown;
  final remaining = expire - DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (remaining < 0) return LoomDiagnosticExpiry.expired;
  if (remaining <= const Duration(days: 3).inSeconds) {
    return LoomDiagnosticExpiry.soon;
  }
  if (remaining <= const Duration(days: 30).inSeconds) {
    return LoomDiagnosticExpiry.month;
  }
  return LoomDiagnosticExpiry.later;
}

LoomDiagnosticQuota _loomSubscriptionQuota(Profile? profile) {
  final info = profile?.subscriptionInfo;
  if (info == null || info.total <= 0) return LoomDiagnosticQuota.unknown;
  final used = info.upload + info.download;
  if (used >= info.total) return LoomDiagnosticQuota.exhausted;
  if ((info.total - used) / info.total <= 0.1) {
    return LoomDiagnosticQuota.low;
  }
  return LoomDiagnosticQuota.available;
}

Rule createLoomAdblockRule() =>
    Rule.parse('GEOSITE,$loomAdblockGeosite,REJECT');

bool isLoomAdblockRule(Rule rule) {
  return rule.ruleAction == RuleAction.GEOSITE &&
      rule.content?.toLowerCase() == loomAdblockGeosite &&
      rule.ruleTarget?.toUpperCase() == RuleTarget.REJECT.name;
}

const _loomDirectActions = {
  RuleAction.DOMAIN,
  RuleAction.DOMAIN_SUFFIX,
  RuleAction.IP_CIDR,
  RuleAction.IP_CIDR6,
};

bool isLoomDirectRule(Rule rule) {
  return !isLoomSupportDirectRule(rule) &&
      _loomDirectActions.contains(rule.ruleAction) &&
      rule.ruleTarget?.toUpperCase() == RuleTarget.DIRECT.name;
}

Rule createLoomSupportDirectRule() =>
    Rule.parse('DOMAIN-SUFFIX,$loomSupportApiHost,DIRECT');

bool isLoomSupportDirectRule(Rule rule) {
  return rule.ruleAction == RuleAction.DOMAIN_SUFFIX &&
      rule.content?.toLowerCase() == loomSupportApiHost &&
      rule.ruleTarget?.toUpperCase() == RuleTarget.DIRECT.name;
}

Rule? createLoomDirectRule(String value) {
  var input = value.trim();
  if (input.isEmpty) return null;

  final uri = Uri.tryParse(input);
  if (uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty) {
    input = uri.host;
  } else if (input.contains('://')) {
    return null;
  }

  final cidr = input.split('/');
  if (cidr.length == 2) {
    final address = InternetAddress.tryParse(cidr.first);
    final prefix = int.tryParse(cidr.last);
    if (address == null || prefix == null) return null;
    final ipv4 = address.type == InternetAddressType.IPv4;
    if (prefix < 0 || prefix > (ipv4 ? 32 : 128)) return null;
    return Rule.parse(
      '${ipv4 ? 'IP-CIDR' : 'IP-CIDR6'},${address.address}/$prefix,DIRECT,no-resolve',
    );
  }
  if (cidr.length != 1) return null;

  final address = InternetAddress.tryParse(input);
  if (address != null) {
    final ipv4 = address.type == InternetAddressType.IPv4;
    return Rule.parse(
      '${ipv4 ? 'IP-CIDR' : 'IP-CIDR6'},${address.address}/${ipv4 ? 32 : 128},DIRECT,no-resolve',
    );
  }

  var domain = input.toLowerCase();
  if (domain.startsWith('*.')) {
    domain = domain.substring(2);
  } else if (domain.startsWith('.')) {
    domain = domain.substring(1);
  }
  if (domain.endsWith('.')) domain = domain.substring(0, domain.length - 1);
  if (domain.isEmpty ||
      domain.length > 253 ||
      RegExp(r'[\s,/:]').hasMatch(domain) ||
      RegExp(r'^[0-9.]+$').hasMatch(domain)) {
    return null;
  }
  final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  if (domain.split('.').any((label) => !labelPattern.hasMatch(label))) {
    return null;
  }
  return Rule.parse('DOMAIN-SUFFIX,$domain,DIRECT');
}

Group? _watchLoomGroup(WidgetRef ref) {
  final groups = ref.watch(currentGroupsStateProvider).value;
  return groups.firstWhereOrNull((group) => group.name == 'LOOM') ??
      groups.firstWhereOrNull((group) => group.type == GroupType.Selector) ??
      groups.firstOrNull;
}

Proxy? _watchSelectedProxy(WidgetRef ref, Group? group) {
  if (group == null) return null;
  final selectedName = ref.watch(selectedProxyNameProvider(group.name));
  return group.all.firstWhereOrNull((proxy) => proxy.name == selectedName) ??
      group.all.firstOrNull;
}

Future<bool> _installLoomSubscription(BuildContext context, String url) async {
  while (true) {
    final imported = await globalState.container
        .read(profilesActionProvider.notifier)
        .addProfileFormURL(url, showError: false);
    if (imported) return true;
    if (!context.mounted) return false;
    final retry = await globalState.showMessage(
      title: 'Не удалось добавить подписку',
      message: const TextSpan(
        text:
            'Проверьте интернет и ссылку. Если подписка истекла, получите новую на loomvpn.pro.',
      ),
      confirmText: 'Попробовать снова',
    );
    if (retry != true) return false;
  }
}

Future<void> _importSubscription(BuildContext context) async {
  final urlLabel = context.appLocalizations.url;
  var value = '';
  while (true) {
    final url = await globalState.showCommonDialog<String>(
      child: InputDialog(
        autovalidateMode: AutovalidateMode.onUnfocus,
        title: 'Добавить подписку LOOM',
        labelText: urlLabel,
        value: value,
        inputFormatters: TextInputLimits.limit(TextInputLimits.url),
        validator: (value) {
          if (value == null || value.isEmpty) return 'Введите ссылку';
          if (!isLoomSubscriptionUrl(value)) {
            return 'Введите ссылку подписки LOOM';
          }
          return null;
        },
      ),
    );
    if (url == null) return;
    value = url;
    if (!context.mounted) return;
    if (await _installLoomSubscription(context, url)) return;
  }
}

bool _isValidLoomEmail(String value) {
  final email = value.trim();
  return email.length <= 254 &&
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
}

String _loomAuthError(BuildContext context, LoomAuthFailure failure) {
  final localizations = context.appLocalizations;
  return switch (failure) {
    LoomAuthFailure.invalidCode => localizations.loomAuthInvalidCode,
    LoomAuthFailure.expiredCode => localizations.loomAuthExpiredCode,
    LoomAuthFailure.rateLimited => localizations.loomAuthRateLimited,
    LoomAuthFailure.subscriptionMissing =>
      localizations.loomAuthSubscriptionMissing,
    LoomAuthFailure.deviceLimit => localizations.loomAuthDeviceLimit,
    LoomAuthFailure.network => localizations.networkException,
    LoomAuthFailure.invalidResponse => localizations.loomAuthInvalidResponse,
  };
}

Future<void> _showLoomAuthError(
  BuildContext context,
  LoomAuthException error,
) async {
  if (!context.mounted) return;
  final localizations = context.appLocalizations;
  await globalState.showMessage(
    context: context,
    title: localizations.loomAuthErrorTitle,
    message: TextSpan(text: _loomAuthError(context, error.failure)),
  );
}

Future<void> _activateLoomSubscription(BuildContext context) async {
  final localizations = context.appLocalizations;
  final email = await globalState.showCommonDialog<String>(
    context: context,
    child: InputDialog(
      title: localizations.loomEmailTitle,
      labelText: localizations.loomEmailLabel,
      value: '',
      maxLength: 254,
      keyboardType: TextInputType.emailAddress,
      inputFormatters: TextInputLimits.limit(254),
      validator: (value) => _isValidLoomEmail(value ?? '')
          ? null
          : localizations.loomEmailInvalid,
    ),
  );
  if (email == null || !context.mounted) return;

  final client = LoomAuthClient(
    platform: Platform.operatingSystem,
    appVersion: globalState.packageInfo.version,
    appBuild: globalState.packageInfo.buildNumber,
  );
  final LoomLoginChallenge challenge;
  try {
    challenge = await client.requestCode(email);
  } on LoomAuthException catch (error) {
    if (!context.mounted) return;
    await _showLoomAuthError(context, error);
    return;
  }

  while (true) {
    if (!context.mounted) return;
    final code = await globalState.showCommonDialog<String>(
      context: context,
      child: InputDialog(
        title: localizations.loomCodeTitle,
        labelText: localizations.loomCodeLabel,
        value: '',
        maxLength: 6,
        keyboardType: TextInputType.number,
        inputFormatters: TextInputLimits.digitsOnly(6),
        validator: (value) => RegExp(r'^\d{6}$').hasMatch(value ?? '')
            ? null
            : localizations.loomCodeInvalid,
      ),
    );
    if (code == null || !context.mounted) return;

    try {
      final activation = await client.activate(
        challenge: challenge,
        code: code,
        installationId: await loomInstallationId(),
      );
      if (!context.mounted) return;
      await _installLoomSubscription(context, activation.subscriptionUrl);
      return;
    } on LoomAuthException catch (error) {
      if (!context.mounted) return;
      await _showLoomAuthError(context, error);
      if (error.failure != LoomAuthFailure.invalidCode) return;
    }
  }
}

Future<void> _applyLoomRules(WidgetRef ref, int profileId) async {
  ref.invalidate(setupStateProvider(profileId));
  await ref
      .read(setupActionProvider.notifier)
      .applyProfile(force: true, silence: true);
}

Future<void> _ensureLoomSupportDirectRule(
  WidgetRef ref,
  Profile? profile,
) async {
  if (profile == null || profile.overwriteType != OverwriteType.standard) {
    return;
  }
  final current = await database.rulesDao
      .queryProfileAddedRules(profile.id)
      .get();
  if (current.any(isLoomSupportDirectRule)) return;
  final value = createLoomSupportDirectRule();
  final rule = value.autoOrder(value, null, current.firstOrNull?.order);
  await database.rulesDao.putProfileAddedRule(profile.id, rule);
  await _applyLoomRules(ref, profile.id);
}

Future<void> _addLoomDirectRule(WidgetRef ref, Profile profile) async {
  if (profile.overwriteType != OverwriteType.standard) return;
  final value = await globalState.showCommonDialog<String>(
    child: InputDialog(
      title: 'Добавить исключение',
      labelText: 'Сайт, IP или CIDR',
      hintText: 'example.com или 192.168.1.0/24',
      value: '',
      inputFormatters: TextInputLimits.limit(TextInputLimits.domain),
      validator: (value) => createLoomDirectRule(value ?? '') == null
          ? 'Введите корректный сайт, IP или CIDR'
          : null,
    ),
  );
  final rule = createLoomDirectRule(value ?? '');
  if (rule == null) return;
  await globalState.safeRun(() async {
    final current = await database.rulesDao
        .queryProfileAddedRules(profile.id)
        .get();
    if (current.any((item) => item.rawValue == rule.rawValue)) {
      globalState.showNotifier('Этот адрес уже добавлен');
      return;
    }
    final ordered = rule.autoOrder(rule, null, current.firstOrNull?.order);
    await database.rulesDao.putProfileAddedRule(profile.id, ordered);
    await _applyLoomRules(ref, profile.id);
  });
}

Future<void> _deleteLoomDirectRule(
  WidgetRef ref,
  Profile profile,
  Rule rule,
) async {
  await globalState.safeRun(() async {
    await database.rulesDao.delRules([rule.id]);
    await _applyLoomRules(ref, profile.id);
  });
}

Future<void> _setAdblock(
  WidgetRef ref,
  Profile profile,
  List<Rule> currentRules,
  bool enabled,
) async {
  if (profile.overwriteType != OverwriteType.standard) {
    globalState.showNotifier('Adblock доступен для стандартного профиля');
    return;
  }
  await globalState.safeRun(() async {
    final matches = currentRules.where(isLoomAdblockRule).toList();
    if (enabled && matches.isEmpty) {
      final value = createLoomAdblockRule();
      final rule = value.autoOrder(
        value,
        null,
        currentRules.firstOrNull?.order,
      );
      await database.rulesDao.putProfileAddedRule(profile.id, rule);
    } else if (!enabled && matches.isNotEmpty) {
      await database.rulesDao.delRules(matches.map((rule) => rule.id));
    }
    await _applyLoomRules(ref, profile.id);
  });
}

class LoomHelloView extends StatefulWidget {
  const LoomHelloView({super.key});

  @override
  State<LoomHelloView> createState() => _LoomHelloViewState();
}

class _LoomHelloViewState extends State<LoomHelloView> {
  bool _activating = false;

  Future<void> _activate() async {
    if (_activating) return;
    setState(() => _activating = true);
    try {
      await _activateLoomSubscription(context);
    } finally {
      if (mounted) setState(() => _activating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = context.appLocalizations;
    return LoomPage(
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: LoomWordmark(),
                ),
                const SizedBox(height: 42),
                Text(
                  localizations.loomHelloTitle,
                  style: const TextStyle(
                    color: loomInk,
                    fontSize: 42,
                    height: 0.94,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -2.6,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  localizations.loomHelloSubtitle,
                  style: const TextStyle(
                    color: loomMuted,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 34),
                LoomPrimaryButton(
                  label: localizations.loomGetSubscription,
                  icon: Icons.open_in_new,
                  onPressed: () => globalState.openUrl(loomSubscriptionUrl),
                ),
                const SizedBox(height: 10),
                LoomPrimaryButton(
                  label: localizations.loomLoginByEmail,
                  outlined: true,
                  icon: Icons.alternate_email,
                  onPressed: _activating ? null : _activate,
                ),
                TextButton(
                  onPressed: _activating
                      ? null
                      : () => _importSubscription(context),
                  child: Text(localizations.loomManualSubscription),
                ),
                TextButton.icon(
                  onPressed: () =>
                      BaseNavigator.push(context, const LoomSupportView()),
                  icon: const LoomSupportUnreadBadge(
                    child: Icon(Icons.support_agent_outlined, size: 18),
                  ),
                  label: Text(localizations.loomNeedHelp),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LoomHomeView extends ConsumerWidget {
  const LoomHomeView({super.key});

  void _toServers(WidgetRef ref) {
    ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.proxies);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider);
    if (profile == null) return const LoomHelloView();
    final isStarted = ref.watch(isStartProvider);
    final group = _watchLoomGroup(ref);
    final proxy = _watchSelectedProxy(ref, group);
    final delay = proxy == null
        ? null
        : ref.watch(
            delayProvider(proxyName: proxy.name, testUrl: group?.testUrl),
          );
    return LoomPage(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxHeight < 680 || constraints.maxWidth < 440;
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const LoomWordmark(),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Настройки',
                      onPressed: () {
                        BaseNavigator.push(context, const LoomSettingsView());
                      },
                      icon: const LoomSupportUnreadBadge(
                        child: Icon(Icons.settings_outlined),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 10 : 18),
                LoomStatus(isStarted: isStarted),
                SizedBox(height: compact ? 10 : 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isStarted
                                ? 'Соединение\nзащищено'
                                : 'Готово к\nподключению',
                            style: const TextStyle(
                              color: loomInk,
                              fontSize: 32,
                              height: 0.94,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -1.8,
                            ).copyWith(fontSize: compact ? 28 : 32),
                          ),
                          SizedBox(height: compact ? 7 : 12),
                          Text(
                            isStarted
                                ? 'Трафик зашифрован. Можно пользоваться интернетом.'
                                : 'Ваши данные сейчас передаются напрямую.',
                            style: const TextStyle(
                              color: loomMuted,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 18),
                    LoomPowerButton(
                      compact: compact,
                      enabled: true,
                      isStarted: isStarted,
                      onPressed: () => ref
                          .read(commonActionProvider.notifier)
                          .toggleRunning(),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 14 : 28),
                LoomCard(
                  padding: EdgeInsets.all(compact ? 12 : 16),
                  onTap: () => _toServers(ref),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const LoomEyebrow('СЕРВЕР'),
                            const SizedBox(height: 8),
                            EmojiText(
                              proxy?.name ?? 'Выберите сервер',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: loomInk,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              group?.name ?? 'LOOM',
                              style: const TextStyle(
                                color: loomMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (delay != null && delay > 0)
                        Text(
                          '$delay мс',
                          style: TextStyle(
                            color: utils.getDelayColor(delay),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right, color: loomInk),
                    ],
                  ),
                ),
                SizedBox(height: compact ? 8 : 10),
                Row(
                  children: [
                    Expanded(
                      child: LoomMetricCard(
                        compact: compact,
                        label: 'ПРОТОКОЛ',
                        value: proxy?.type.toUpperCase() ?? '—',
                        caption: 'Автовыбор',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: LoomMetricCard(
                        compact: compact,
                        label: 'ПИНГ',
                        value: delay != null && delay > 0 ? '$delay мс' : '—',
                        caption: delay == 0
                            ? 'Проверяем'
                            : delay != null && delay < 0
                            ? 'Нет ответа'
                            : 'Нажмите сервер',
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 8 : 10),
                if (isStarted)
                  LoomTrafficCard(compact: compact)
                else
                  LoomAdblockCard(profile: profile, compact: compact),
                SizedBox(height: compact ? 12 : 18),
                LoomPrimaryButton(
                  compact: compact,
                  label: isStarted ? 'ОТКЛЮЧИТЬСЯ' : 'ПОДКЛЮЧИТЬСЯ',
                  outlined: isStarted,
                  onPressed: () =>
                      ref.read(commonActionProvider.notifier).toggleRunning(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class LoomServersView extends ConsumerStatefulWidget {
  const LoomServersView({super.key});

  @override
  ConsumerState<LoomServersView> createState() => _LoomServersViewState();
}

class _LoomServersViewState extends ConsumerState<LoomServersView> {
  String _query = '';
  bool _testing = false;

  Future<void> _select(Group group, Proxy proxy) async {
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(group.name, proxy.name);
    ref
        .read(proxiesActionProvider.notifier)
        .changeProxyDebounce(group.name, proxy.name);
  }

  Future<void> _test(Group group) async {
    if (_testing) return;
    setState(() => _testing = true);
    await delayTest(group.all, group.testUrl);
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final group = _watchLoomGroup(ref);
    final selectedName = group == null
        ? null
        : ref.watch(selectedProxyNameProvider(group.name));
    final proxies =
        group?.all
            .where(
              (proxy) => proxy.name.toLowerCase().contains(
                _query.trim().toLowerCase(),
              ),
            )
            .toList() ??
        const <Proxy>[];
    return LoomPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'СЕРВЕРЫ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: loomInk,
                    fontWeight: FontWeight.w500,
                    fontSize: 20,
                    letterSpacing: -0.9,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Проверить задержку',
                onPressed: group == null || _testing
                    ? null
                    : () => _test(group),
                icon: _testing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.speed_outlined),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              hintText: 'Поиск сервера',
              prefixIcon: Icon(Icons.search),
              filled: true,
              fillColor: loomSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(3)),
                borderSide: BorderSide(color: loomBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(3)),
                borderSide: BorderSide(color: loomBorder),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const LoomEyebrow('ВСЕ СЕРВЕРЫ'),
          const SizedBox(height: 8),
          Expanded(
            child: group == null
                ? Center(
                    child: LoomPrimaryButton(
                      label: 'ДОБАВИТЬ ПОДПИСКУ',
                      onPressed: () => _importSubscription(context),
                    ),
                  )
                : LoomCard(
                    padding: EdgeInsets.zero,
                    child: ListView.separated(
                      itemCount: proxies.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final proxy = proxies[index];
                        return LoomProxyTile(
                          group: group,
                          proxy: proxy,
                          selected: selectedName == proxy.name,
                          onTap: () => _select(group, proxy),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class LoomStatisticsView extends ConsumerWidget {
  const LoomStatisticsView({super.key});

  List<Point> _points(List<Traffic> traffic) {
    if (traffic.isEmpty) return const [Point(0, 0), Point(1, 0)];
    return traffic
        .asMap()
        .entries
        .map(
          (entry) => Point(entry.key.toDouble(), entry.value.speed.toDouble()),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(trafficsProvider).list;
    final current = history.safeLast(const Traffic());
    final total = ref.watch(totalTrafficProvider);
    final runTime = ref.watch(runTimeProvider);
    final isStarted = ref.watch(isStartProvider);
    return LoomPage(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'СТАТИСТИКА',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: loomInk,
                fontWeight: FontWeight.w500,
                fontSize: 20,
                letterSpacing: -0.9,
              ),
            ),
            const SizedBox(height: 18),
            LoomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const LoomEyebrow('СКОРОСТЬ СЕЙЧАС'),
                      const Spacer(),
                      Text(
                        current.speedText,
                        style: const TextStyle(color: loomMuted, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 170,
                    child: LineChart(
                      color: loomAccent,
                      gradient: true,
                      duration: const Duration(milliseconds: 220),
                      points: _points(history),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: LoomMetricCard(
                    label: 'ОТПРАВЛЕНО',
                    value: total.up.traffic.show,
                    caption: 'Текущая сессия',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: LoomMetricCard(
                    label: 'ПОЛУЧЕНО',
                    value: total.down.traffic.show,
                    caption: 'Текущая сессия',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LoomCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  LoomValueRow(
                    icon: Icons.power_settings_new,
                    label: 'Подключение',
                    value: isStarted ? utils.getTimeText(runTime) : 'Отключено',
                  ),
                  const Divider(height: 1),
                  LoomValueRow(
                    icon: Icons.upload_outlined,
                    label: 'Исходящая скорость',
                    value: '${current.up.traffic.show}/с',
                  ),
                  const Divider(height: 1),
                  LoomValueRow(
                    icon: Icons.download_outlined,
                    label: 'Входящая скорость',
                    value: '${current.down.traffic.show}/с',
                  ),
                  const Divider(height: 1),
                  LoomValueRow(
                    icon: Icons.data_usage_outlined,
                    label: 'Передано данных',
                    value: (total.up + total.down).traffic.show,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LoomSettingsView extends ConsumerWidget {
  const LoomSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider);
    final appSettings = ref.watch(appSettingProvider);
    final group = _watchLoomGroup(ref);
    final proxy = _watchSelectedProxy(ref, group);
    final directRules = profile == null
        ? const <Rule>[]
        : (ref.watch(profileAddedRulesProvider(profile.id)).value ?? [])
              .where(isLoomDirectRule)
              .toList();
    return LoomDetailPage(
      title: 'Настройки',
      child: ListView(
        children: [
          const LoomSectionTitle('ПОДКЛЮЧЕНИЕ'),
          LoomCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                LoomSwitchRow(
                  label: 'Автоподключение',
                  caption: 'Запускать VPN вместе с клиентом',
                  value: appSettings.autoRun,
                  onChanged: (value) {
                    ref
                        .read(appSettingProvider.notifier)
                        .update((state) => state.copyWith(autoRun: value));
                  },
                ),
                if (system.isDesktop) ...[
                  const Divider(height: 1),
                  LoomSwitchRow(
                    label: 'Автозапуск',
                    caption: 'Открывать LOOM после входа в систему',
                    value: appSettings.autoLaunch,
                    onChanged: (value) {
                      ref
                          .read(appSettingProvider.notifier)
                          .update((state) => state.copyWith(autoLaunch: value));
                    },
                  ),
                ],
                const Divider(height: 1),
                LoomSettingsRow(
                  label: 'Протокол',
                  value: proxy?.type.toUpperCase() ?? 'Автовыбор',
                ),
                const Divider(height: 1),
                LoomSettingsRow(
                  label: 'Проверка соединения',
                  onTap: proxy == null
                      ? null
                      : () => proxyDelayTest(proxy, group?.testUrl),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const LoomSectionTitle('КОНФИДЕНЦИАЛЬНОСТЬ'),
          if (profile == null)
            const LoomCard(
              child: Text('Добавьте подписку, чтобы включить adblock.'),
            )
          else
            LoomAdblockCard(profile: profile, compact: true),
          const SizedBox(height: 10),
          LoomCard(
            padding: EdgeInsets.zero,
            child: LoomSettingsRow(
              label: 'Сайты напрямую',
              value: profile == null
                  ? 'Нужна подписка'
                  : profile.overwriteType != OverwriteType.standard
                  ? 'Недоступно'
                  : '${directRules.length}',
              onTap:
                  profile != null &&
                      profile.overwriteType == OverwriteType.standard
                  ? () => BaseNavigator.push(
                      context,
                      LoomSplitTunnelView(profile: profile),
                    )
                  : null,
            ),
          ),
          if (system.isAndroid) ...[
            const SizedBox(height: 10),
            LoomCard(
              padding: EdgeInsets.zero,
              child: LoomSettingsRow(
                label: 'Раздельное туннелирование',
                onTap: () => BaseNavigator.push(context, const AccessView()),
              ),
            ),
          ],
          const SizedBox(height: 22),
          const LoomSectionTitle('АККАУНТ И ПОМОЩЬ'),
          LoomCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                LoomSettingsRow(
                  label: 'Управление подпиской',
                  onTap: () {
                    BaseNavigator.push(context, const LoomSubscriptionView());
                  },
                ),
                const Divider(height: 1),
                ValueListenableBuilder<bool>(
                  valueListenable: loomSupportInbox,
                  builder: (context, unread, child) => LoomSettingsRow(
                    label: 'Поддержка',
                    showBadge: unread,
                    onTap: () {
                      BaseNavigator.push(context, const LoomSupportView());
                    },
                  ),
                ),
                const Divider(height: 1),
                LoomSettingsRow(
                  label: 'Версия',
                  value: globalState.packageInfo.version,
                ),
                if (system.isMacOS) ...[
                  const Divider(height: 1),
                  const LoomSettingsRow(
                    label: 'Проверить обновления',
                    onTap: checkForAppUpdates,
                  ),
                ],
                const Divider(height: 1),
                LoomSettingsRow(
                  label: 'Исходный код и лицензия',
                  onTap: () =>
                      globalState.openUrl('https://github.com/$repository'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LoomSplitTunnelView extends ConsumerWidget {
  final Profile profile;

  const LoomSplitTunnelView({super.key, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = (ref.watch(profileAddedRulesProvider(profile.id)).value ?? [])
        .where(isLoomDirectRule)
        .toList();
    return LoomDetailPage(
      title: 'Сайты напрямую',
      child: ListView(
        children: [
          const LoomCard(
            child: Text(
              'Добавленные сайты и адреса обходят VPN. Домен включает все его поддомены.',
              style: TextStyle(color: loomMuted, fontSize: 12, height: 1.4),
            ),
          ),
          const SizedBox(height: 10),
          LoomPrimaryButton(
            label: 'ДОБАВИТЬ САЙТ ИЛИ АДРЕС',
            icon: Icons.add,
            onPressed: () => _addLoomDirectRule(ref, profile),
          ),
          const SizedBox(height: 18),
          if (rules.isEmpty)
            const Center(
              child: Text(
                'Исключений пока нет',
                style: TextStyle(color: loomMuted, fontSize: 12),
              ),
            )
          else
            LoomCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final (index, rule) in rules.indexed) ...[
                    if (index > 0) const Divider(height: 1),
                    ListTile(
                      title: Text(
                        rule.content ?? '',
                        style: const TextStyle(
                          color: loomInk,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        rule.ruleAction.value,
                        style: const TextStyle(color: loomMuted, fontSize: 10),
                      ),
                      trailing: IconButton(
                        tooltip: 'Удалить',
                        onPressed: () =>
                            _deleteLoomDirectRule(ref, profile, rule),
                        icon: const Icon(Icons.delete_outline, size: 20),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class LoomSupportView extends ConsumerStatefulWidget {
  const LoomSupportView({super.key});

  @override
  ConsumerState<LoomSupportView> createState() => _LoomSupportViewState();
}

class _LoomPreparedSubscription {
  final Profile candidate;
  final int servers;

  const _LoomPreparedSubscription(this.candidate, this.servers);
}

class _LoomSupportViewState extends ConsumerState<LoomSupportView>
    with WidgetsBindingObserver, ActivePollingMixin<LoomSupportView> {
  static const _quickMessages = [
    'Не подключается',
    'Нет интернета',
    'Отключается',
    'Медленная скорость',
    'Не открывается сайт',
    'Проблема с подпиской',
  ];

  late final LoomSupportClient _client;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<LoomSupportMessage> _messages = [];
  bool _loading = true;
  bool _ready = false;
  bool _sending = false;
  bool _directRuleReady = false;
  int? _busyActionId;
  int _afterId = 0;
  String? _error;

  @override
  Duration get pollInterval => const Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _client = sharedLoomSupportClient(
      platform: Platform.operatingSystem,
      appVersion: globalState.packageInfo.version,
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Future<void> poll(PollGuard isCurrent) async {
    try {
      if (!_directRuleReady) {
        try {
          await _ensureLoomSupportDirectRule(
            ref,
            ref.read(currentProfileProvider),
          );
        } catch (error, stackTrace) {
          commonPrint.log(
            'support DIRECT rule failed: $error\n$stackTrace',
            logLevel: LogLevel.warning,
          );
        }
        _directRuleReady = true;
      }
      if (!_ready) {
        final credential = await _client.ensureOpenThread();
        await loomSupportInbox.activate(credential.supportId);
        _ready = true;
      }
      var supportId = _client.credential!.supportId;
      var messages = await _client.listMessages(afterId: _afterId);
      final currentSupportId = _client.credential!.supportId;
      final identityChanged = currentSupportId != supportId;
      if (identityChanged) {
        supportId = currentSupportId;
        await loomSupportInbox.activate(supportId);
        messages = await _client.listMessages(afterId: 0);
      }
      if (!isCurrent()) return;
      if (messages.any((message) => message.eventKind == 'thread_closed_v1')) {
        await _client.ensureOpenThread();
      }
      setState(() {
        if (identityChanged) {
          _messages.clear();
          _afterId = 0;
        }
        _merge(messages);
        _loading = false;
        _error = null;
      });
      await loomSupportInbox.markSeenThrough(supportId, _afterId);
    } catch (error, stackTrace) {
      commonPrint.log(
        'support poll failed: $error\n$stackTrace',
        logLevel: LogLevel.warning,
      );
      if (!isCurrent()) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось связаться с поддержкой';
      });
    }
  }

  void _merge(Iterable<LoomSupportMessage> incoming) {
    for (final message in incoming) {
      final index = _messages.indexWhere((item) => item.id == message.id);
      if (index == -1) {
        _messages.add(message);
      } else {
        _messages[index] = message;
      }
    }
    _messages.sort((a, b) => a.id.compareTo(b.id));
    if (_messages.isNotEmpty) _afterId = _messages.last.id;
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendText([String? generatedText]) async {
    final text = (generatedText ?? _textController.text).trim();
    if (text.isEmpty || _sending || !_ready) return;
    if (utf8.encode(text).length > 4096) {
      globalState.showNotifier('Сообщение слишком длинное');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final message = await _client.postText(text);
      if (!mounted) return;
      setState(() {
        _merge([message]);
        if (generatedText == null) _textController.clear();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось отправить сообщение');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<String> _safeDiagnosticReport() async {
    final profile = ref.read(currentProfileProvider);
    final groups = ref.read(currentGroupsStateProvider).value;
    final group =
        groups.firstWhereOrNull((item) => item.name == 'LOOM') ??
        groups.firstWhereOrNull((item) => item.type == GroupType.Selector) ??
        groups.firstOrNull;
    final selectedName = group == null
        ? null
        : ref.read(selectedProxyNameProvider(group.name));
    final proxy =
        group?.all.firstWhereOrNull((item) => item.name == selectedName) ??
        group?.all.firstOrNull;
    final connections = await Connectivity().checkConnectivity();
    return buildLoomSafeDiagnosticReport(
      appVersion: globalState.packageInfo.version,
      platform: Platform.operatingSystem,
      vpnConnected: ref.read(isStartProvider),
      coreStatus: ref.read(coreStatusProvider),
      proxyType: proxy?.type,
      proxySelection: _loomProxySelection(proxy, group),
      subscriptionPresent: profile != null,
      subscriptionFreshness: _loomSubscriptionFreshness(profile),
      subscriptionExpiry: _loomSubscriptionExpiry(profile),
      subscriptionQuota: _loomSubscriptionQuota(profile),
      connectivity: _loomConnectivity(connections),
    );
  }

  Future<String> _diagnosticReportV2({
    LoomSupportNetworkContext? network,
  }) async {
    final profile = ref.read(currentProfileProvider);
    final groups = ref.read(currentGroupsStateProvider).value;
    final group =
        groups.firstWhereOrNull((item) => item.name == 'LOOM') ??
        groups.firstWhereOrNull((item) => item.type == GroupType.Selector) ??
        groups.firstOrNull;
    final selectedName = group == null
        ? null
        : ref.read(selectedProxyNameProvider(group.name));
    final proxy =
        group?.all.firstWhereOrNull((item) => item.name == selectedName) ??
        group?.all.firstOrNull;
    final rules = profile == null
        ? const <Rule>[]
        : await database.rulesDao.queryProfileAddedRules(profile.id).get();
    VersionInfo coreVersion;
    try {
      coreVersion = await coreController.getVersion();
    } catch (_) {
      coreVersion = const VersionInfo();
    }
    final connectivity = await Connectivity().checkConnectivity();
    final lastNetworkFailure = ref
        .read(logsProvider)
        .list
        .lastWhereOrNull(
          (log) =>
              log.logLevel == LogLevel.error &&
              RegExp(
                r'network|connect|timeout|dns|socket|dial',
                caseSensitive: false,
              ).hasMatch(log.payload),
        );
    final subscription = profile?.subscriptionInfo;
    return buildLoomDiagnosticReportV2(
      appVersion: globalState.packageInfo.version,
      appBuild: globalState.packageInfo.buildNumber,
      platform: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
      architecture: Abi.current().toString(),
      coreName: coreVersion.clashName,
      coreVersion: coreVersion.version,
      vpnConnected: ref.read(isStartProvider),
      coreStatus: ref.read(coreStatusProvider).name,
      mode: ref.read(patchClashConfigProvider).mode.name,
      tunEnabled: ref.read(patchClashConfigProvider).tun.enable,
      systemProxyEnabled: ref.read(networkSettingProvider).systemProxy,
      serverName: proxy?.name,
      proxyType: proxy?.type,
      pingMs: proxy == null
          ? null
          : ref.read(
              delayProvider(proxyName: proxy.name, testUrl: group?.testUrl),
            ),
      uptimeMs: ref.read(runTimeProvider),
      subscriptionUpdatedAt: profile?.lastUpdateDate,
      subscriptionExpiresAt: subscription == null || subscription.expire <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(subscription.expire * 1000),
      subscriptionUsedBytes: subscription == null
          ? null
          : subscription.upload + subscription.download,
      subscriptionTotalBytes: subscription?.total,
      adblockEnabled: rules.any(isLoomAdblockRule),
      directRules: rules.where(isLoomDirectRule).length,
      lastNetworkFailureAt: lastNetworkFailure?.dateTime,
      connectivity: _loomConnectivity(connectivity).name,
      network: network,
    );
  }

  Future<_LoomPreparedSubscription?> _prepareSubscriptionReplacement(
    Profile current,
  ) async {
    var value = '';
    while (mounted) {
      final url = await globalState.showCommonDialog<String>(
        child: InputDialog(
          autovalidateMode: AutovalidateMode.onUnfocus,
          title: 'Заменить подписку',
          labelText: 'Ссылка подписки',
          value: value,
          inputFormatters: TextInputLimits.limit(TextInputLimits.url),
          validator: (value) {
            if (!isLoomSubscriptionUrl(value ?? '')) {
              return 'Введите ссылку подписки LOOM';
            }
            return null;
          },
        ),
      );
      if (url == null) return null;
      value = url.trim();
      final candidate = await globalState.loadingRun(
        tag: LoadingTag.profiles,
        () => Profile.normal(url: value).update(),
        title: 'Проверяем подписку',
        showError: false,
      );
      if (candidate == null) {
        final retry = await globalState.showMessage(
          title: 'Подписка не прошла проверку',
          message: const TextSpan(
            text: 'Старая подписка не изменена. Проверьте ссылку и интернет.',
          ),
          confirmText: 'ПОПРОБОВАТЬ СНОВА',
        );
        if (retry != true) return null;
        continue;
      }
      try {
        final config = await coreController.getConfig(candidate.id);
        final servers = config['proxies'] is List
            ? (config['proxies'] as List).length
            : 0;
        final expire = candidate.subscriptionInfo?.expire ?? 0;
        final expiry = expire <= 0
            ? 'не указано'
            : DateFormat(
                'dd.MM.yyyy',
              ).format(DateTime.fromMillisecondsSinceEpoch(expire * 1000));
        final confirmed = await globalState.showMessage(
          title: 'Подписка готова',
          message: TextSpan(
            text:
                'Серверов: $servers\nДействует до: $expiry\n\nТекущая подписка будет заменена только после подтверждения.',
          ),
          confirmText: 'ЗАМЕНИТЬ',
        );
        if (confirmed == true) {
          return _LoomPreparedSubscription(candidate, servers);
        }
      } catch (_) {
        globalState.showNotifier('Не удалось прочитать новую подписку');
      }
      if (candidate.id != current.id) {
        await File(
          await appPath.getProfilePath(candidate.id.toString()),
        ).safeDelete();
      }
      return null;
    }
    return null;
  }

  Future<void> _commitSubscriptionReplacement(
    Profile current,
    _LoomPreparedSubscription prepared,
  ) async {
    final targetPath = await appPath.getProfilePath(current.id.toString());
    final candidatePath = await appPath.getProfilePath(
      prepared.candidate.id.toString(),
    );
    final staged = File('$targetPath.loom-replacement');
    final backup = File('$targetPath.loom-backup');
    final target = File(targetPath);
    final replacement = current.copyWith(
      url: prepared.candidate.url,
      lastUpdateDate: prepared.candidate.lastUpdateDate,
      subscriptionInfo: prepared.candidate.subscriptionInfo,
    );
    await File(candidatePath).copy(staged.path);
    if (await target.exists()) await target.copy(backup.path);
    try {
      await staged.rename(targetPath);
      await database.profilesDao.putAll([replacement.toCompanion()]);
      ref.read(profilesProvider.notifier).put(replacement);
      ref.invalidate(setupStateProvider(current.id));
      await ref
          .read(setupActionProvider.notifier)
          .applyProfile(force: true, silence: true);
    } catch (_) {
      if (await backup.exists()) await backup.copy(targetPath);
      await database.profilesDao.putAll([current.toCompanion()]);
      ref.read(profilesProvider.notifier).put(current);
      ref.invalidate(setupStateProvider(current.id));
      try {
        await ref
            .read(setupActionProvider.notifier)
            .applyProfile(force: true, silence: true);
      } catch (_) {}
      rethrow;
    } finally {
      await staged.safeDelete();
      await backup.safeDelete();
      await File(candidatePath).safeDelete();
    }
  }

  Future<void> _replaceSubscription(Profile profile) async {
    final prepared = await _prepareSubscriptionReplacement(profile);
    if (prepared == null) return;
    await _commitSubscriptionReplacement(profile, prepared);
    globalState.showNotifier(
      'Подписка заменена · серверов: ${prepared.servers}',
    );
  }

  Future<void> _respond(
    LoomSupportMessage message, {
    required bool accept,
    String? choiceId,
  }) async {
    if (!message.isPendingAction ||
        !message.isSupportedAction ||
        _busyActionId != null ||
        _sending) {
      return;
    }
    final profile = ref.read(currentProfileProvider);
    if (accept &&
        (message.actionKind == 'refresh_subscription_v1' ||
            message.actionKind == 'replace_subscription_v1' ||
            message.actionPayload['screen'] == 'split_tunneling') &&
        profile == null) {
      globalState.showNotifier('Сначала добавьте подписку');
      return;
    }

    String? report;
    _LoomPreparedSubscription? preparedSubscription;
    if (accept && message.actionKind == 'request_diagnostics_v1') {
      report = await _safeDiagnosticReport();
      if (!mounted) return;
      final confirmed = await globalState.showMessage(
        title: 'Отправить диагностику?',
        message: TextSpan(
          text:
              'В поддержку уйдут только версия клиента и общие статусы VPN, сети и подписки. IP, модель устройства, версия ОС, Wi-Fi SSID, имя сервера, ссылка подписки, логи, файлы и скриншоты не отправляются.\n\n$report',
        ),
        confirmText: 'ОТПРАВИТЬ',
      );
      if (confirmed != true) return;
    }
    if (accept && message.actionKind == 'request_diagnostics_v2') {
      report = await _diagnosticReportV2();
      if (!mounted) return;
      final confirmed = await globalState.showMessage(
        title: 'Отправить полную диагностику?',
        message: TextSpan(
          text:
              'Оператор увидит версии клиента и Core, macOS и архитектуру, режим подключения, выбранный сервер, протокол, ping, uptime, даты и лимиты подписки, adblock, число DIRECT-правил и время последней сетевой ошибки. Ссылка подписки и логи не отправляются.\n\n$report',
        ),
        confirmText: 'ОТПРАВИТЬ',
      );
      if (confirmed != true) return;
      final includeNetwork = await globalState.showMessage(
        title: 'Добавить данные сети?',
        message: const TextSpan(
          text:
              'Отдельно можно передать публичный IP, страну, ASN и название оператора. Данные запрашиваются только сейчас через HTTPS-сервер LOOM.',
        ),
        confirmText: 'ДОБАВИТЬ',
        cancelText: 'БЕЗ НИХ',
      );
      if (includeNetwork == true) {
        try {
          report = await _diagnosticReportV2(
            network: await _client.getNetworkContext(),
          );
        } catch (_) {
          globalState.showNotifier('Данные сети недоступны — отправим без них');
        }
      }
    }
    if (accept && message.actionKind == 'detect_network_conflicts_v1') {
      report = await detectLoomNetworkConflicts(
        loomConnected: ref.read(isStartProvider),
      );
      if (!mounted) return;
      final confirmed = await globalState.showMessage(
        title: 'Отправить найденные настройки?',
        message: TextSpan(
          text:
              'Оператор увидит активные VPN-сервисы, utun-интерфейсы, default route, включённые системные прокси и DNS. Ничего на Mac не изменяется.\n\n$report',
        ),
        confirmText: 'ОТПРАВИТЬ',
      );
      if (confirmed != true) return;
    }
    if (accept && message.actionKind == 'replace_subscription_v1') {
      preparedSubscription = await _prepareSubscriptionReplacement(profile!);
      if (preparedSubscription == null) return;
    }

    setState(() {
      _busyActionId = message.id;
      _error = null;
    });
    try {
      final updated = await _client.respondToAction(
        message.id,
        accept: accept,
        choiceId: choiceId,
      );
      if (!mounted) return;
      setState(() => _merge([updated]));
      if (!accept) return;
      switch (message.actionKind) {
        case 'request_diagnostics_v1':
        case 'request_diagnostics_v2':
          await _sendText('Диагностика с согласия пользователя:\n$report');
          break;
        case 'detect_network_conflicts_v1':
          await _sendText('Проверка сетевых конфликтов:\n$report');
          break;
        case 'refresh_subscription_v1':
          await ref
              .read(profilesActionProvider.notifier)
              .updateProfile(profile!, showLoading: true);
          globalState.showNotifier('Подписка обновлена');
          break;
        case 'replace_subscription_v1':
          await _commitSubscriptionReplacement(profile!, preparedSubscription!);
          globalState.showNotifier('Подписка заменена');
          break;
        case 'open_screen_v1':
          await _openScreen(message.actionPayload['screen'] as String);
          break;
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Действие не выполнено. Попробуйте ещё раз');
      }
    } finally {
      if (preparedSubscription != null) {
        await File(
          await appPath.getProfilePath(
            preparedSubscription.candidate.id.toString(),
          ),
        ).safeDelete();
      }
      if (mounted) setState(() => _busyActionId = null);
    }
  }

  Future<void> _openScreen(String screen) async {
    switch (screen) {
      case 'home':
        ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.dashboard);
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      case 'routes':
        ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.proxies);
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      case 'statistics':
        ref
            .read(currentPageLabelProvider.notifier)
            .toPage(PageLabel.statistics);
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      case 'settings':
        stopPolling();
        await BaseNavigator.push(context, const LoomSettingsView());
        if (mounted) restartPolling();
        return;
      case 'split_tunneling':
        final profile = ref.read(currentProfileProvider);
        if (profile == null) return;
        stopPolling();
        await BaseNavigator.push(
          context,
          LoomSplitTunnelView(profile: profile),
        );
        if (mounted) restartPolling();
        return;
      case 'support':
        return;
    }
  }

  String _actionTitle(LoomSupportMessage message) =>
      switch (message.actionKind) {
        'choice_v1' =>
          message.actionPayload['prompt'] as String? ?? 'Выберите вариант',
        'request_diagnostics_v1' => 'Отправить диагностику',
        'request_diagnostics_v2' => 'Отправить полную диагностику',
        'detect_network_conflicts_v1' => 'Проверить сетевые конфликты',
        'replace_subscription_v1' => 'Заменить подписку',
        'refresh_subscription_v1' => 'Обновить подписку',
        'open_screen_v1' => 'Открыть экран в приложении',
        _ => 'Неподдерживаемое действие',
      };

  String _eventTitle(LoomSupportMessage message) => switch (message.eventKind) {
    'plan_changed_v1' => '✓ Тариф изменён',
    'days_added_v1' => '✓ Подписка продлена',
    'traffic_added_v1' => '✓ Добавлен трафик',
    'device_limit_changed_v1' => '✓ Лимит устройств изменён',
    'subscription_reissued_v1' => '✓ Подписка перевыпущена',
    'incident_resolved_v1' => '✓ Проблема устранена',
    'thread_closed_v1' => '✓ Обращение закрыто',
    _ => 'Обновление сервиса',
  };

  String _eventDetail(LoomSupportMessage message) {
    final payload = message.eventPayload;
    return switch (message.eventKind) {
      'plan_changed_v1' => 'Новый тариф: ${payload['plan_name']}',
      'days_added_v1' =>
        'Срок действия подписки продлён до: ${_eventDate(payload['expires_on'] as String?)}',
      'traffic_added_v1' => 'К подписке добавлено ${payload['gigabytes']} ГБ.',
      'device_limit_changed_v1' =>
        'Теперь можно подключить устройств: ${payload['limit']}.',
      'subscription_reissued_v1' =>
        'Старая ссылка может больше не работать. Введите новую ссылку локально.',
      'incident_resolved_v1' =>
        'Инцидент устранён. Можно повторить подключение.',
      'thread_closed_v1' => 'Если проблема вернётся, напишите новое сообщение.',
      _ => 'Обновите экран поддержки.',
    };
  }

  String _eventDate(String? value) {
    final date = DateTime.tryParse(value ?? '');
    return date == null
        ? value ?? 'не указан'
        : DateFormat('dd.MM.yyyy').format(date);
  }

  Future<void> _handleEvent(LoomSupportMessage message) async {
    if (_busyActionId != null) return;
    final profile = ref.read(currentProfileProvider);
    if (profile == null) {
      globalState.showNotifier('Сначала добавьте подписку');
      return;
    }
    setState(() => _busyActionId = message.id);
    try {
      if (message.eventKind == 'subscription_reissued_v1') {
        await _replaceSubscription(profile);
      } else {
        await ref
            .read(profilesActionProvider.notifier)
            .updateProfile(profile, showLoading: true);
        globalState.showNotifier('Подписка обновлена');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось обновить подписку');
    } finally {
      if (mounted) setState(() => _busyActionId = null);
    }
  }

  Widget _event(LoomSupportMessage message) {
    final canRefresh = const {
      'plan_changed_v1',
      'days_added_v1',
      'traffic_added_v1',
      'device_limit_changed_v1',
      'subscription_reissued_v1',
    }.contains(message.eventKind);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LoomCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _eventTitle(message),
              style: const TextStyle(
                color: loomInk,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _eventDetail(message),
              style: const TextStyle(
                color: loomMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            if (canRefresh) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busyActionId == null
                    ? () => _handleEvent(message)
                    : null,
                child: Text(
                  message.eventKind == 'subscription_reissued_v1'
                      ? 'ЗАМЕНИТЬ ПОДПИСКУ'
                      : 'ОБНОВИТЬ ПОДПИСКУ',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _message(LoomSupportMessage message) {
    if (message.kind == 'action') return _action(message);
    if (message.kind == 'event') return _event(message);
    final mine = message.senderKind == 'client';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? loomAccent : loomSurfaceRaised,
          border: mine ? null : Border.all(color: loomBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: SelectableText(
          message.text,
          style: TextStyle(
            color: mine ? Colors.white : loomInk,
            fontSize: 13,
            height: 1.35,
          ),
        ),
      ),
    );
  }

  Widget _action(LoomSupportMessage message) {
    final pending = message.isPendingAction && message.isSupportedAction;
    final busy = _busyActionId == message.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LoomCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LoomEyebrow('ЗАПРОС ОПЕРАТОРА'),
            const SizedBox(height: 8),
            Text(
              _actionTitle(message),
              style: const TextStyle(
                color: loomInk,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (message.actionKind == 'request_diagnostics_v1') ...[
              const SizedBox(height: 6),
              const Text(
                'Только общие статусы. Без IP, данных устройства, имени сервера, логов и ссылки подписки.',
                style: TextStyle(color: loomMuted, fontSize: 10, height: 1.35),
              ),
            ],
            if (message.actionKind == 'request_diagnostics_v2') ...[
              const SizedBox(height: 6),
              const Text(
                'Версии, режим подключения, выбранный сервер, ping и точные данные подписки. IP и оператор — только с отдельного согласия.',
                style: TextStyle(color: loomMuted, fontSize: 10, height: 1.35),
              ),
            ],
            if (message.actionKind == 'detect_network_conflicts_v1') ...[
              const SizedBox(height: 6),
              const Text(
                'Только читает VPN-сервисы, маршруты, системные прокси и DNS. Ничего не меняет.',
                style: TextStyle(color: loomMuted, fontSize: 10, height: 1.35),
              ),
            ],
            if (message.actionKind == 'replace_subscription_v1') ...[
              const SizedBox(height: 6),
              const Text(
                'Новая ссылка вводится и проверяется только на этом устройстве. Оператор её не увидит.',
                style: TextStyle(color: loomMuted, fontSize: 10, height: 1.35),
              ),
            ],
            const SizedBox(height: 12),
            if (busy)
              const Center(child: CircularProgressIndicator(strokeWidth: 2))
            else if (pending && message.actionKind == 'choice_v1') ...[
              for (final choice in message.choices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: OutlinedButton(
                    onPressed: () =>
                        _respond(message, accept: true, choiceId: choice.id),
                    child: Text(choice.label),
                  ),
                ),
              TextButton(
                onPressed: () => _respond(message, accept: false),
                child: const Text('ОТКЛОНИТЬ'),
              ),
            ] else if (pending)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _respond(message, accept: false),
                      child: const Text('ОТКЛОНИТЬ'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _respond(message, accept: true),
                      child: const Text('РАЗРЕШИТЬ'),
                    ),
                  ),
                ],
              )
            else
              Text(switch (message.actionState) {
                'accepted' => 'Разрешено',
                'declined' => 'Отклонено',
                _ => 'Запрос истёк или не поддерживается',
              }, style: const TextStyle(color: loomMuted, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supportId = _client.credential?.supportId;
    return LoomDetailPage(
      title: 'Поддержка',
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.support_agent_outlined, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Чат с командой LOOM',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              if (supportId != null)
                Text(
                  'ID ${supportId.length > 8 ? supportId.substring(0, 8) : supportId}',
                  style: const TextStyle(color: loomMuted, fontSize: 9),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            MaterialBanner(
              content: Text(_error!, style: const TextStyle(fontSize: 11)),
              actions: [
                TextButton(
                  onPressed: restartPolling,
                  child: const Text('ПОВТОРИТЬ'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Опишите проблему — оператор ответит здесь.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: loomMuted, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _messages.length,
                    itemBuilder: (_, index) => _message(_messages[index]),
                  ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final text in _quickMessages)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(text),
                      onPressed: !_ready || _sending
                          ? null
                          : () => _sendText(text),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  enabled: _ready && !_sending,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: 'Сообщение',
                    filled: true,
                    fillColor: loomSurface,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Отправить',
                onPressed: !_ready || _sending ? null : _sendText,
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.arrow_upward),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => globalState.openUrl(loomGuideUrl),
            child: const Text('База знаний'),
          ),
        ],
      ),
    );
  }
}

class LoomSubscriptionView extends ConsumerWidget {
  const LoomSubscriptionView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider);
    final info = profile?.subscriptionInfo;
    final used = (info?.upload ?? 0) + (info?.download ?? 0);
    final expires = info?.expire != null && info!.expire > 0
        ? DateFormat(
            'dd.MM.yyyy',
          ).format(DateTime.fromMillisecondsSinceEpoch(info.expire * 1000))
        : 'Не указан';
    return LoomDetailPage(
      title: 'Подписка',
      child: ListView(
        children: [
          if (profile == null)
            LoomPrimaryButton(
              label: 'ДОБАВИТЬ ПОДПИСКУ',
              onPressed: () => _importSubscription(context),
            )
          else ...[
            LoomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const LoomEyebrow('ПОДПИСКА'),
                  const SizedBox(height: 8),
                  Text(
                    profile.label,
                    style: const TextStyle(
                      color: loomInk,
                      fontSize: 28,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -1.4,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Действует до $expires',
                    style: const TextStyle(color: loomSuccess, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  LoomValueRow(
                    icon: Icons.data_usage_outlined,
                    label: 'Использовано',
                    value: used.traffic.show,
                    dense: true,
                  ),
                  if ((info?.total ?? 0) > 0) ...[
                    const Divider(height: 1),
                    LoomValueRow(
                      icon: Icons.all_inclusive,
                      label: 'Лимит',
                      value: info!.total.traffic.show,
                      dense: true,
                    ),
                  ],
                  const SizedBox(height: 16),
                  LoomPrimaryButton(
                    label: 'ПРОДЛИТЬ ПОДПИСКУ',
                    onPressed: () => globalState.openUrl(loomSubscriptionUrl),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            LoomCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  LoomSettingsRow(
                    label: 'Обновить подписку',
                    onTap: () => ref
                        .read(profilesActionProvider.notifier)
                        .updateProfile(profile, showLoading: true),
                  ),
                  const Divider(height: 1),
                  LoomSettingsRow(
                    label: 'Заменить ссылку',
                    onTap: () => _importSubscription(context),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class LoomPage extends StatelessWidget {
  final Widget child;

  const LoomPage({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: loomBackground,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class LoomDetailPage extends StatelessWidget {
  final String title;
  final Widget child;

  const LoomDetailPage({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: loomBackground,
      appBar: AppBar(
        backgroundColor: loomBackground,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          title,
          style: const TextStyle(
            color: loomInk,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: child,
          ),
        ),
      ),
    );
  }
}

class LoomWordmark extends StatelessWidget {
  const LoomWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    return const Text.rich(
      TextSpan(
        text: 'LOOM',
        children: [
          TextSpan(
            text: '.',
            style: TextStyle(color: loomAccent),
          ),
        ],
      ),
      style: TextStyle(
        color: loomInk,
        fontSize: 23,
        height: 1,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.6,
      ),
    );
  }
}

class LoomStatus extends StatelessWidget {
  final bool isStarted;

  const LoomStatus({super.key, required this.isStarted});

  @override
  Widget build(BuildContext context) {
    final color = isStarted ? loomSuccess : loomMuted;
    return Row(
      children: [
        Icon(Icons.circle, color: color, size: 8),
        const SizedBox(width: 8),
        Text(
          isStarted ? 'ПОДКЛЮЧЕНО' : 'ОТКЛЮЧЕНО',
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

class LoomPowerButton extends StatelessWidget {
  final bool compact;
  final bool enabled;
  final bool isStarted;
  final VoidCallback onPressed;

  const LoomPowerButton({
    super.key,
    this.compact = false,
    required this.enabled,
    required this.isStarted,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final diameter = compact ? 88.0 : 116.0;
    return Semantics(
      button: true,
      label: enabled
          ? isStarted
                ? 'Отключить VPN'
                : 'Подключить VPN'
          : 'Добавить подписку',
      child: Container(
        width: diameter,
        height: diameter,
        padding: EdgeInsets.all(compact ? 6 : 8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: enabled ? loomAccent : loomBorder),
          boxShadow: enabled
              ? const [BoxShadow(color: Color(0x22FF3300), blurRadius: 34)]
              : null,
        ),
        child: Material(
          color: loomBackground,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(
              enabled ? Icons.power_settings_new : Icons.add_link,
              size: compact ? 31 : 38,
              color: enabled ? loomInk : loomMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class LoomCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const LoomCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(4),
      side: const BorderSide(color: loomBorder),
    );
    return Material(
      color: loomSurface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class LoomEyebrow extends StatelessWidget {
  final String text;

  const LoomEyebrow(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: loomAccent,
        fontSize: 9,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.3,
      ),
    );
  }
}

class LoomSectionTitle extends StatelessWidget {
  final String text;

  const LoomSectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: LoomEyebrow(text),
    );
  }
}

class LoomMetricCard extends StatelessWidget {
  final bool compact;
  final String label;
  final String value;
  final String caption;

  const LoomMetricCard({
    super.key,
    this.compact = false,
    required this.label,
    required this.value,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return LoomCard(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LoomEyebrow(label),
          SizedBox(height: compact ? 7 : 12),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: loomInk,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: compact ? 3 : 7),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: loomMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class LoomPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool outlined;
  final bool compact;
  final VoidCallback? onPressed;

  const LoomPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.outlined = false,
    this.compact = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 19), const SizedBox(width: 8)],
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
      ],
    );
    final style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(
        Size.fromHeight(compact ? 44 : 50),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    );
    return SizedBox(
      width: double.infinity,
      child: outlined
          ? OutlinedButton(
              style: style.copyWith(
                foregroundColor: const WidgetStatePropertyAll(loomInk),
                side: const WidgetStatePropertyAll(
                  BorderSide(color: loomBorder),
                ),
              ),
              onPressed: onPressed,
              child: child,
            )
          : FilledButton(
              style: style.copyWith(
                backgroundColor: const WidgetStatePropertyAll(loomAccent),
                foregroundColor: const WidgetStatePropertyAll(Colors.white),
              ),
              onPressed: onPressed,
              child: child,
            ),
    );
  }
}

class LoomAdblockCard extends ConsumerWidget {
  final Profile profile;
  final bool compact;

  const LoomAdblockCard({
    super.key,
    required this.profile,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(profileAddedRulesProvider(profile.id)).value ?? [];
    final enabled = rules.any(isLoomAdblockRule);
    return LoomCard(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: loomInk, size: 30),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) ...[
                  const LoomEyebrow('КОНФИДЕНЦИАЛЬНОСТЬ'),
                  const SizedBox(height: 7),
                ],
                const Text(
                  'Блокировка рекламы',
                  style: TextStyle(
                    color: loomInk,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  enabled ? 'Рекламные домены блокируются' : 'Выключена',
                  style: const TextStyle(color: loomMuted, fontSize: 10),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            activeThumbColor: Colors.white,
            activeTrackColor: loomAccent,
            onChanged: (value) => _setAdblock(ref, profile, rules, value),
          ),
        ],
      ),
    );
  }
}

class LoomTrafficCard extends ConsumerWidget {
  final bool compact;

  const LoomTrafficCard({super.key, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(totalTrafficProvider);
    final history = ref.watch(trafficsProvider).list;
    final points = history.isEmpty
        ? const [Point(0, 0), Point(1, 0)]
        : history
              .asMap()
              .entries
              .map(
                (entry) =>
                    Point(entry.key.toDouble(), entry.value.speed.toDouble()),
              )
              .toList();
    return LoomCard(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LoomEyebrow('ТРАФИК СЕССИИ'),
          SizedBox(height: compact ? 6 : 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  total.up.traffic.show,
                  style: const TextStyle(
                    color: loomInk,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  total.down.traffic.show,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: loomInk,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 4 : 6),
          const Row(
            children: [
              Expanded(
                child: Text(
                  'Отправлено',
                  style: TextStyle(color: loomMuted, fontSize: 9),
                ),
              ),
              Expanded(
                child: Text(
                  'Получено',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: loomMuted, fontSize: 9),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 4 : 8),
          SizedBox(
            height: compact ? 18 : 34,
            child: LineChart(color: loomAccent, points: points),
          ),
        ],
      ),
    );
  }
}

class LoomProxyTile extends ConsumerWidget {
  final Group group;
  final Proxy proxy;
  final bool selected;
  final VoidCallback onTap;

  const LoomProxyTile({
    super.key,
    required this.group,
    required this.proxy,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final delay = ref.watch(
      delayProvider(proxyName: proxy.name, testUrl: group.testUrl),
    );
    return ListTile(
      onTap: onTap,
      minVerticalPadding: 12,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? loomAccent : loomBorder,
      ),
      title: EmojiText(
        proxy.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: loomInk,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        proxy.type.toUpperCase(),
        style: const TextStyle(color: loomMuted, fontSize: 10),
      ),
      trailing: delay != null && delay > 0
          ? Text(
              '$delay мс',
              style: TextStyle(
                color: utils.getDelayColor(delay),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            )
          : IconButton(
              tooltip: 'Проверить задержку',
              onPressed: () => proxyDelayTest(proxy, group.testUrl),
              icon: delay == 0
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt_outlined, size: 20),
            ),
    );
  }
}

class LoomValueRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool dense;

  const LoomValueRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: dense ? 0 : 16, vertical: 13),
      child: Row(
        children: [
          Icon(icon, color: loomInk, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: loomInk, fontSize: 12),
            ),
          ),
          Text(value, style: const TextStyle(color: loomMuted, fontSize: 11)),
        ],
      ),
    );
  }
}

class LoomSwitchRow extends StatelessWidget {
  final String label;
  final String caption;
  final bool value;
  final ValueChanged<bool> onChanged;

  const LoomSwitchRow({
    super.key,
    required this.label,
    required this.caption,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: loomInk,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  caption,
                  style: const TextStyle(color: loomMuted, fontSize: 10),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: Colors.white,
            activeTrackColor: loomAccent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class LoomSettingsRow extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback? onTap;
  final bool showBadge;

  const LoomSettingsRow({
    super.key,
    required this.label,
    this.value,
    this.onTap,
    this.showBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      title: Text(
        label,
        style: const TextStyle(
          color: loomInk,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Badge(
            isLabelVisible: showBadge,
            smallSize: 8,
            backgroundColor: loomAccent,
          ),
          if (showBadge) const SizedBox(width: 8),
          if (value != null)
            Text(
              value!,
              style: const TextStyle(color: loomMuted, fontSize: 11),
            ),
          if (onTap != null) const Icon(Icons.chevron_right, size: 20),
        ],
      ),
    );
  }
}

class LoomSupportUnreadBadge extends StatelessWidget {
  final Widget child;

  const LoomSupportUnreadBadge({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: loomSupportInbox,
      child: child,
      builder: (context, unread, child) => Badge(
        isLabelVisible: unread,
        smallSize: 8,
        backgroundColor: loomAccent,
        child: child,
      ),
    );
  }
}

class LoomLinkCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const LoomLinkCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return LoomCard(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: loomInk),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: loomInk,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(color: loomMuted, fontSize: 10),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
