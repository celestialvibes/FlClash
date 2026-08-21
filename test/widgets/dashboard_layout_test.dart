import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/home.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/loom.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('root hides navigation until a subscription exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profilesProvider.overrideWith(_EmptyProfiles.new),
          viewSizeProvider.overrideWithValue(const Size(800, 600)),
        ],
        child: const _TestApp(child: LoomRootView()),
      ),
    );

    expect(find.byType(LoomHelloView), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('hello screen leads with subscription actions', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [viewSizeProvider.overrideWithValue(const Size(800, 600))],
        child: const _TestApp(child: LoomHelloView()),
      ),
    );

    expect(find.text('LOOM.'), findsOneWidget);
    expect(find.text('Личная сеть.\nНа вашей стороне.'), findsOneWidget);
    expect(find.text('ПОЛУЧИТЬ ПОДПИСКУ'), findsOneWidget);
    expect(find.text('ВОЙТИ В LOOM'), findsOneWidget);
    expect(find.text('Ввести подписку вручную'), findsOneWidget);
    expect(find.text('Нужна помощь?'), findsOneWidget);

    await tester.tap(find.text('ВОЙТИ В LOOM'));
    await tester.pumpAndSettle();

    expect(find.text('Войти в LOOM'), findsOneWidget);
    expect(find.text('Продолжить через Telegram'), findsOneWidget);
    expect(find.text('ВОЙТИ ПО ПОЧТЕ'), findsOneWidget);

    await tester.tap(find.text('ВОЙТИ ПО ПОЧТЕ'));
    await tester.pumpAndSettle();

    expect(find.text('Войти в LOOM'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'not an email');
    await tester.tap(find.text('Отправить'));
    await tester.pump();

    expect(find.text('Введите корректную почту'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ввести подписку вручную'));
    await tester.pumpAndSettle();

    expect(find.text('Добавить подписку LOOM'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'not a url');
    await tester.tap(find.byType(TextButton).last);
    await tester.pump();

    expect(find.text('Введите ссылку подписки LOOM'), findsOneWidget);
    expect(find.text('not a url'), findsOneWidget);
    expect(tester.takeException(), null);
  });
}

class _EmptyProfiles extends Profiles {
  @override
  List<Profile> build() => const [];
}

class _TestApp extends StatelessWidget {
  final Widget child;

  const _TestApp({required this.child});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: const Locale('ru'),
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
