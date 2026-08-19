import 'dart:io';

import 'package:collection/collection.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/access.dart';
import 'package:fl_clash/views/logs.dart';
import 'package:fl_clash/views/proxies/common.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

const loomAccent = Color(0xFFFF3300);
const loomBackground = Color(0xFFF2F2EF);
const loomInk = Color(0xFF0F0F0F);
const loomMuted = Color(0xFF666666);
const loomBorder = Color(0xFFD8D8D5);

const loomSupportUrl = 'https://t.me/l00mvpnsupport';
const loomSubscriptionUrl = 'https://t.me/l00mvpn_bot';
const loomGuideUrl = 'https://loomhost.ru/start';
const loomStatusUrl = 'https://loomhost.ru/';
const loomAdblockGeosite = 'category-ads-all';

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
  return _loomDirectActions.contains(rule.ruleAction) &&
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

Future<void> _importSubscription(BuildContext context) async {
  final appLocalizations = context.appLocalizations;
  final url = await globalState.showCommonDialog<String>(
    child: InputDialog(
      autovalidateMode: AutovalidateMode.onUnfocus,
      title: 'Добавить подписку LOOM',
      labelText: appLocalizations.url,
      value: '',
      inputFormatters: TextInputLimits.limit(TextInputLimits.url),
      validator: (value) {
        if (value == null || value.isEmpty) return 'Введите ссылку';
        if (!value.isUrl) return 'Проверьте ссылку';
        return null;
      },
    ),
  );
  if (url == null) return;
  await globalState.container
      .read(profilesActionProvider.notifier)
      .addProfileFormURL(url);
}

Future<void> _applyLoomRules(WidgetRef ref, int profileId) async {
  ref.invalidate(setupStateProvider(profileId));
  await ref
      .read(setupActionProvider.notifier)
      .applyProfile(force: true, silence: true);
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

class LoomHelloView extends StatelessWidget {
  const LoomHelloView({super.key});

  @override
  Widget build(BuildContext context) {
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
                const Text(
                  'ДОБРО ПОЖАЛОВАТЬ\nВ LOOM.',
                  style: TextStyle(
                    color: loomInk,
                    fontSize: 38,
                    height: 0.92,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.8,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Оформите подписку — бот выдаст ссылку для подключения.',
                  style: TextStyle(color: loomMuted, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 34),
                LoomPrimaryButton(
                  label: 'ПОЛУЧИТЬ ПОДПИСКУ',
                  icon: Icons.open_in_new,
                  onPressed: () => globalState.openUrl(loomSubscriptionUrl),
                ),
                const SizedBox(height: 10),
                LoomPrimaryButton(
                  label: 'ЕСТЬ ПОДПИСКА?',
                  outlined: true,
                  icon: Icons.add_link,
                  onPressed: () => _importSubscription(context),
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
      child: SingleChildScrollView(
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
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
            const SizedBox(height: 18),
            LoomStatus(isStarted: isStarted),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isStarted
                            ? 'СОЕДИНЕНИЕ\nЗАЩИЩЕНО'
                            : 'ИНТЕРНЕТ\nБЕЗ ЗАЩИТЫ',
                        style: const TextStyle(
                          color: loomInk,
                          fontSize: 26,
                          height: 0.95,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.2,
                        ),
                      ),
                      const SizedBox(height: 12),
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
                  enabled: true,
                  isStarted: isStarted,
                  onPressed: () =>
                      ref.read(commonActionProvider.notifier).toggleRunning(),
                ),
              ],
            ),
            const SizedBox(height: 28),
            LoomCard(
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
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: LoomMetricCard(
                    label: 'ПРОТОКОЛ',
                    value: proxy?.type.toUpperCase() ?? '—',
                    caption: 'Автовыбор',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: LoomMetricCard(
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
            const SizedBox(height: 10),
            if (isStarted)
              const LoomTrafficCard()
            else
              LoomAdblockCard(profile: profile),
            const SizedBox(height: 18),
            LoomPrimaryButton(
              label: isStarted ? 'ОТКЛЮЧИТЬСЯ' : 'ПОДКЛЮЧИТЬСЯ',
              outlined: isStarted,
              onPressed: () =>
                  ref.read(commonActionProvider.notifier).toggleRunning(),
            ),
          ],
        ),
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
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                    letterSpacing: -0.6,
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
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
                borderSide: BorderSide(color: loomBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
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
                fontWeight: FontWeight.w900,
                fontSize: 20,
                letterSpacing: -0.6,
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
                LoomSettingsRow(
                  label: 'Поддержка',
                  onTap: () {
                    BaseNavigator.push(context, const LoomSupportView());
                  },
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

class LoomSupportView extends StatelessWidget {
  const LoomSupportView({super.key});

  @override
  Widget build(BuildContext context) {
    return LoomDetailPage(
      title: 'Поддержка',
      child: ListView(
        children: [
          LoomLinkCard(
            icon: Icons.menu_book_outlined,
            title: 'База знаний',
            subtitle: 'Настройка и ответы на частые вопросы',
            onTap: () => globalState.openUrl(loomGuideUrl),
          ),
          const SizedBox(height: 10),
          LoomLinkCard(
            icon: Icons.mail_outline,
            title: 'Написать в поддержку',
            subtitle: '@l00mvpnsupport',
            onTap: () => globalState.openUrl(loomSupportUrl),
          ),
          const SizedBox(height: 10),
          LoomLinkCard(
            icon: Icons.send_outlined,
            title: 'Telegram-бот',
            subtitle: 'Покупка, продление и управление',
            onTap: () => globalState.openUrl(loomSubscriptionUrl),
          ),
          const SizedBox(height: 10),
          LoomLinkCard(
            icon: Icons.receipt_long_outlined,
            title: 'Журнал подключения',
            subtitle: 'Техническая диагностика клиента',
            onTap: () => BaseNavigator.push(context, const LogsView()),
          ),
          const SizedBox(height: 24),
          LoomCard(
            onTap: () => globalState.openUrl(loomStatusUrl),
            child: const Row(
              children: [
                Icon(Icons.circle, color: Color(0xFF14963C), size: 10),
                SizedBox(width: 10),
                Expanded(child: Text('Проверить статус сервисов')),
                Icon(Icons.open_in_new, size: 18),
              ],
            ),
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
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Действует до $expires',
                    style: const TextStyle(
                      color: Color(0xFF14963C),
                      fontSize: 12,
                    ),
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
    return const Text(
      'LOOM.',
      style: TextStyle(
        color: loomInk,
        fontSize: 25,
        height: 1,
        fontWeight: FontWeight.w900,
        letterSpacing: -1.8,
      ),
    );
  }
}

class LoomStatus extends StatelessWidget {
  final bool isStarted;

  const LoomStatus({super.key, required this.isStarted});

  @override
  Widget build(BuildContext context) {
    final color = isStarted ? const Color(0xFF14963C) : loomAccent;
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
  final bool enabled;
  final bool isStarted;
  final VoidCallback onPressed;

  const LoomPowerButton({
    super.key,
    required this.enabled,
    required this.isStarted,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: enabled
          ? isStarted
                ? 'Отключить VPN'
                : 'Подключить VPN'
          : 'Добавить подписку',
      child: Container(
        width: 108,
        height: 108,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: enabled ? loomAccent : loomBorder),
        ),
        child: Material(
          color: enabled ? loomAccent : loomBorder,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(
              enabled ? Icons.power_settings_new : Icons.add_link,
              size: 42,
              color: Colors.white,
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
      borderRadius: BorderRadius.circular(8),
      side: const BorderSide(color: loomBorder),
    );
    return Material(
      color: Colors.white,
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
        color: loomMuted,
        fontSize: 9,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
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
  final String label;
  final String value;
  final String caption;

  const LoomMetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return LoomCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LoomEyebrow(label),
          const SizedBox(height: 12),
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
          const SizedBox(height: 7),
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
  final VoidCallback onPressed;

  const LoomPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.outlined = false,
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
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(50)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
    );
    return SizedBox(
      width: double.infinity,
      child: outlined
          ? OutlinedButton(
              style: style.copyWith(
                foregroundColor: const WidgetStatePropertyAll(loomInk),
                side: const WidgetStatePropertyAll(BorderSide(color: loomInk)),
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
                  enabled
                      ? 'Рекламные домены блокируются'
                      : 'Используется база доменов Mihomo',
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
  const LoomTrafficCard({super.key});

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LoomEyebrow('ТРАФИК СЕССИИ'),
          const SizedBox(height: 12),
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
          const SizedBox(height: 6),
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
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
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

  const LoomSettingsRow({
    super.key,
    required this.label,
    this.value,
    this.onTap,
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
