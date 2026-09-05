import 'dart:async';

import 'package:fl_clash/widgets/active_polling.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('restarting polling does not overlap a pending request', (
    tester,
  ) async {
    final key = GlobalKey<_ProbeState>();
    await tester.pumpWidget(_Probe(key: key));
    final state = key.currentState!;
    expect(state.calls, 1);

    for (var i = 0; i < 5; i++) {
      state.restartPolling();
    }
    await tester.pump(const Duration(seconds: 2));
    expect(state.calls, 1);

    state.response.complete();
    await tester.pump();
    expect(state.applied, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(state.calls, 2);
    expect(state.applied, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    expect(state.calls, 2);
  });
}

class _Probe extends StatefulWidget {
  const _Probe({super.key});

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe>
    with WidgetsBindingObserver, ActivePollingMixin<_Probe> {
  final response = Completer<void>();
  int calls = 0;
  int applied = 0;

  @override
  Duration get pollInterval => const Duration(seconds: 1);

  @override
  Future<void> poll(PollGuard isCurrent) async {
    calls++;
    await response.future;
    if (isCurrent()) applied++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
