import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DashboardView extends ConsumerWidget {
  const DashboardView({super.key});

  Future<void> _handleImportSubscription(BuildContext context) async {
    final appLocalizations = context.appLocalizations;
    final url = await globalState.showCommonDialog<String>(
      child: InputDialog(
        autovalidateMode: AutovalidateMode.onUnfocus,
        title: appLocalizations.addProfile,
        labelText: appLocalizations.url,
        value: '',
        inputFormatters: TextInputLimits.limit(TextInputLimits.url),
        validator: (value) {
          if (value == null || value.isEmpty) {
            return appLocalizations.emptyTip('').trim();
          }
          if (!isLoomSubscriptionUrl(value)) {
            return 'Введите ссылку подписки LOOM';
          }
          return null;
        },
      ),
    );
    if (url == null) {
      return;
    }
    await globalState.container
        .read(profilesActionProvider.notifier)
        .addProfileFormURL(url);
    if (globalState.container.read(profilesProvider).isNotEmpty) {
      globalState.container
          .read(currentPageLabelProvider.notifier)
          .toPage(PageLabel.dashboard);
    }
  }

  void _toPage(WidgetRef ref, PageLabel pageLabel) {
    ref.read(currentPageLabelProvider.notifier).toPage(pageLabel);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final profile = ref.watch(currentProfileProvider);
    final isStart = ref.watch(isStartProvider);
    return CommonScaffold(
      title: 'LOOM.',
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  profile == null
                      ? Icons.add_link_rounded
                      : Icons.shield_outlined,
                  color: context.colorScheme.primary,
                  size: 72,
                ),
                const SizedBox(height: 24),
                Text(
                  profile?.label ?? appLocalizations.nullProfileDesc,
                  textAlign: TextAlign.center,
                  style: context.textTheme.headlineSmall?.toSoftBold,
                ),
                const SizedBox(height: 24),
                if (profile == null)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _handleImportSubscription(context),
                      icon: const Icon(Icons.link_rounded),
                      label: Text(appLocalizations.addProfile),
                    ),
                  )
                else ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: () => _toPage(ref, PageLabel.proxies),
                      icon: const Icon(Icons.dns_outlined),
                      label: Text(appLocalizations.proxies),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        ref.read(commonActionProvider.notifier).toggleRunning();
                      },
                      icon: Icon(
                        isStart ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      ),
                      label: Text(
                        isStart
                            ? appLocalizations.stop
                            : appLocalizations.start,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => _toPage(ref, PageLabel.profiles),
                    icon: const Icon(Icons.folder_outlined),
                    label: Text(appLocalizations.profiles),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
