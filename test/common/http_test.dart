import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('global HTTP override keeps platform certificate validation', () {
    final source = File('lib/common/http.dart').readAsStringSync();

    expect(source, isNot(contains('badCertificateCallback')));
  });
}
