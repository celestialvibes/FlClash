import 'dart:async';

import 'package:app_links/app_links.dart';

import 'print.dart';

typedef InstallConfigCallBack = void Function(String url);

const _loomSubscriptionHosts = {'lmvn.pro', 'loomvpn.pro', 'loomhost.ru'};

bool isLoomSubscriptionUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return _loomSubscriptionHosts.any(
    (root) => host == root || host.endsWith('.$root'),
  );
}

class LinkManager {
  static LinkManager? _instance;
  late AppLinks _appLinks;
  StreamSubscription? subscription;

  LinkManager._internal() {
    _appLinks = AppLinks();
  }

  Future<void> initAppLinksListen(
    Function(String url) installConfigCallBack,
  ) async {
    commonPrint.log('initAppLinksListen');
    destroy();
    subscription = _appLinks.uriLinkStream.listen((uri) {
      commonPrint.log('onAppLink received');
      final url = extractAddUrl(uri);
      if (url != null) {
        installConfigCallBack(url);
      }
    });
  }

  static String? extractAddUrl(Uri uri) {
    if (uri.scheme != 'loomvpn' || uri.host != 'add') {
      return null;
    }
    final value = uri.queryParameters['url'];
    if (value == null || !isLoomSubscriptionUrl(value)) {
      return null;
    }
    return value;
  }

  void destroy() {
    if (subscription != null) {
      subscription?.cancel();
      subscription = null;
    }
  }

  factory LinkManager() {
    _instance ??= LinkManager._internal();
    return _instance!;
  }
}

final linkManager = LinkManager();
