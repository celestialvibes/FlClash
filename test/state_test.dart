import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GlobalState exposes a fallback accent color before plugin startup', () {
    expect(GlobalState().accentColor, const Color(defaultPrimaryColor));
  });

  test('GlobalState can suppress raw errors while still cleaning up', () async {
    var ended = false;
    final result = await GlobalState().safeRun<int>(
      () => throw 'raw backend error',
      showError: false,
      onEnd: () => ended = true,
    );

    expect(result, isNull);
    expect(ended, isTrue);
  });
}
