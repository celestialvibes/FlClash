import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'subscription errors distinguish failures without exposing credentials',
    () async {
      final l10n = await AppLocalizations.load(const Locale('ru'));
      final options = RequestOptions(
        path: 'https://lmvn.pro/secret-token?credential=private',
      );
      for (final entry in {
        404: l10n.loomSubscriptionInvalidLink,
        410: l10n.loomSubscriptionInvalidLink,
        403: l10n.loomSubscriptionDenied,
        429: l10n.loomAuthRateLimited,
        503: l10n.loomSubscriptionUnavailable,
      }.entries) {
        final error = SubscriptionDownloadException(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: options,
              statusCode: entry.key,
              data: 'secret-token',
            ),
          ),
        );
        expect(error.toString(), entry.value);
        expect(error.toString(), isNot(contains('secret-token')));
        expect(error.toString(), isNot(contains('private')));
      }
      for (final entry in {
        DioExceptionType.connectionTimeout: l10n.loomSubscriptionTimeout,
        DioExceptionType.receiveTimeout: l10n.loomSubscriptionTimeout,
        DioExceptionType.connectionError: l10n.networkException,
      }.entries) {
        expect(
          SubscriptionDownloadException(
            DioException(requestOptions: options, type: entry.key),
          ).toString(),
          entry.value,
        );
      }
    },
  );
}
