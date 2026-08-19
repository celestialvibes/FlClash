import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/loom.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('hello screen leads with subscription actions', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [viewSizeProvider.overrideWithValue(const Size(800, 600))],
        child: const _TestApp(child: LoomHelloView()),
      ),
    );

    expect(find.text('LOOM.'), findsOneWidget);
    expect(find.text('ДОБРО ПОЖАЛОВАТЬ\nВ LOOM.'), findsOneWidget);
    expect(find.text('ПОЛУЧИТЬ ПОДПИСКУ'), findsOneWidget);
    expect(find.text('ЕСТЬ ПОДПИСКА?'), findsOneWidget);

    await tester.tap(find.text('ЕСТЬ ПОДПИСКА?'));
    await tester.pumpAndSettle();

    expect(find.text('Добавить подписку LOOM'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'not a url');
    await tester.tap(find.byType(TextButton).last);
    await tester.pump();

    expect(find.text('Проверьте ссылку'), findsOneWidget);
    expect(find.text('not a url'), findsOneWidget);
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
