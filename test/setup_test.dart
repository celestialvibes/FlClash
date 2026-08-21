import 'package:test/test.dart';

import '../setup.dart' as setup;

void main() {
  group('setup.dart', () {
    test('parses -v as verbose mode', () {
      final results = setup.createSetupArgParser().parse(['android', '-v']);

      expect(results['verbose'], isTrue);
      expect(results.rest, ['android']);
    });

    test('accepts dev application environment', () {
      final results = setup.createSetupArgParser().parse([
        'android',
        '--env',
        'dev',
      ]);

      expect(results['env'], 'dev');
    });

    test('Flutter build environment does not depend on Core SHA256', () {
      expect(setup.createBuildEnvironment('dev', environment: const {}), {
        'APP_ENV': 'dev',
      });
    });

    test('passes configured Firebase identifiers to Flutter', () {
      expect(
        setup.createBuildEnvironment(
          'prod',
          environment: const {
            'LOOM_FIREBASE_API_KEY': 'key',
            'LOOM_FIREBASE_PROJECT_ID': 'project',
            'LOOM_FIREBASE_APP_ID': 'app',
            'LOOM_FIREBASE_MESSAGING_SENDER_ID': 'sender',
          },
        ),
        {
          'APP_ENV': 'prod',
          'LOOM_FIREBASE_API_KEY': 'key',
          'LOOM_FIREBASE_PROJECT_ID': 'project',
          'LOOM_FIREBASE_APP_ID': 'app',
          'LOOM_FIREBASE_MESSAGING_SENDER_ID': 'sender',
        },
      );
    });

    test('omits verbose from flutter build args by default', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'android',
        verbose: false,
      );

      expect(args, ['dart-define-from-file=env.json', 'split-per-abi']);
    });

    test('adds verbose to flutter build args with -v', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'android',
        verbose: true,
      );

      expect(args, [
        'verbose',
        'dart-define-from-file=env.json',
        'split-per-abi',
      ]);
    });
  });
}
