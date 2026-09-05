import 'dart:io';

import 'package:fl_clash/common/file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'validated writes preserve the working config until replacement',
    () async {
      final root = await Directory.systemTemp.createTemp('loom-profile-test-');
      addTearDown(() => root.delete(recursive: true));
      final target = File('${root.path}/profile.yaml');
      await target.writeAsString('working');

      await expectLater(
        target.writeValidatedBytes(
          'invalid'.codeUnits,
          validate: (_) async => 'invalid config',
        ),
        throwsA('invalid config'),
      );
      expect(await target.readAsString(), 'working');
      expect(await root.list().length, 1);

      await target.writeValidatedBytes(
        'updated'.codeUnits,
        validate: (path) async {
          expect(await target.readAsString(), 'working');
          expect(await File(path).readAsString(), 'updated');
          expect(File(path).parent.parent.path, target.parent.path);
          return '';
        },
      );
      expect(await target.readAsString(), 'updated');
      expect(await root.list().length, 1);

      final missing = File('${root.path}/missing.yaml');
      await expectLater(
        missing.writeValidatedBytes(
          'invalid'.codeUnits,
          validate: (_) async => throw StateError('core unavailable'),
        ),
        throwsStateError,
      );
      expect(await missing.exists(), isFalse);
      expect(await root.list().length, 1);
    },
  );
}
