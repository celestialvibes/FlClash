import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/dashboard.dart';
import 'package:fl_clash/widgets/grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dashboard leads with subscription import', (tester) async {
    final container = ProviderContainer(
      overrides: [
        currentProfileProvider.overrideWithValue(null),
        isStartProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _TestApp(child: DashboardView()),
      ),
    );

    expect(find.text('LOOM.'), findsOneWidget);
    expect(find.text('Import a subscription to get started'), findsOneWidget);
    expect(find.text('Import subscription'), findsOneWidget);
    expect(find.byType(Grid), findsNothing);
    expect(tester.takeException(), null);
  });

  testWidgets('dashboard exposes server and connect actions', (tester) async {
    final container = ProviderContainer(
      overrides: [
        currentProfileProvider.overrideWithValue(
          const Profile(
            id: 1,
            label: 'My subscription',
            autoUpdateDuration: Duration(days: 1),
          ),
        ),
        isStartProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _TestApp(child: DashboardView()),
      ),
    );

    expect(find.text('My subscription'), findsOneWidget);
    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Subscriptions'), findsOneWidget);
    expect(tester.takeException(), null);
  });
}

class _TestApp extends StatelessWidget {
  final Widget child;

  const _TestApp({required this.child});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: globalState.navigatorKey,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.delegate.supportedLocales,
      builder: (context, child) {
        globalState.measure = Measure.of(context, 1);
        globalState.theme = CommonTheme.of(context, 1);
        return child!;
      },
      home: child,
    );
  }
}
