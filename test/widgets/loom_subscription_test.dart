import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/views/loom.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

void main() {
  testWidgets('expired subscription shows renewal instead of active status', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentProfileProvider.overrideWith(
            (_) => Profile.normal(
              label: 'LOOM',
            ).copyWith(subscriptionInfo: const SubscriptionInfo(expire: 1)),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('ru'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: [Locale('ru')],
          home: LoomSubscriptionView(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(AppLocalizations.current.loomSubscriptionExpired),
      findsOneWidget,
    );
    expect(find.textContaining('Действует до'), findsNothing);
  });
}
