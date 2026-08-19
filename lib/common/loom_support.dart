import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'preferences.dart';
import 'utils.dart';

const loomSupportApiBaseUrl = String.fromEnvironment(
  'LOOM_SUPPORT_API_BASE_URL',
  defaultValue: 'https://loomvpn.pro',
);

const _credentialKey = 'loomSupportCredentialV1';
const _supportPath = '/api/v1/support';

Uri get loomSupportApiUri {
  final uri = Uri.tryParse(loomSupportApiBaseUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.origin != loomSupportApiBaseUrl) {
    throw StateError('LOOM_SUPPORT_API_BASE_URL must be an HTTPS origin');
  }
  return uri;
}

String get loomSupportApiHost => loomSupportApiUri.host.toLowerCase();

class LoomSupportCredential {
  final String supportId;
  final String bearerToken;

  const LoomSupportCredential({
    required this.supportId,
    required this.bearerToken,
  });

  factory LoomSupportCredential.fromJson(Map<String, dynamic> json) {
    final supportId = json['support_id'];
    final bearerToken = json['bearer_token'];
    if (supportId is! String ||
        supportId.isEmpty ||
        bearerToken is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(bearerToken)) {
      throw const FormatException('invalid support credential');
    }
    return LoomSupportCredential(
      supportId: supportId,
      bearerToken: bearerToken,
    );
  }

  Map<String, String> toJson() => {
    'support_id': supportId,
    'bearer_token': bearerToken,
  };
}

class LoomSupportChoice {
  final String id;
  final String label;

  const LoomSupportChoice({required this.id, required this.label});
}

class LoomSupportMessage {
  final int id;
  final String senderKind;
  final String kind;
  final String text;
  final String? actionKind;
  final Map<String, dynamic> actionPayload;
  final String? actionState;
  final String? actionChoiceId;
  final DateTime? actionExpiresAt;
  final DateTime createdAt;

  const LoomSupportMessage({
    required this.id,
    required this.senderKind,
    required this.kind,
    required this.text,
    required this.actionKind,
    required this.actionPayload,
    required this.actionState,
    required this.actionChoiceId,
    required this.actionExpiresAt,
    required this.createdAt,
  });

  factory LoomSupportMessage.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final senderKind = json['sender_kind'];
    final kind = json['kind'];
    final createdAt = DateTime.tryParse(json['created_at'] as String? ?? '');
    if (id is! num ||
        senderKind is! String ||
        kind is! String ||
        createdAt == null) {
      throw const FormatException('invalid support message');
    }
    return LoomSupportMessage(
      id: id.toInt(),
      senderKind: senderKind,
      kind: kind,
      text: json['text'] as String? ?? '',
      actionKind: json['action_kind'] as String?,
      actionPayload: _mapOrEmpty(json['action_payload']),
      actionState: json['action_state'] as String?,
      actionChoiceId: json['action_choice_id'] as String?,
      actionExpiresAt: DateTime.tryParse(
        json['action_expires_at'] as String? ?? '',
      ),
      createdAt: createdAt,
    );
  }

  bool get isPendingAction =>
      kind == 'action' &&
      actionState == 'pending' &&
      actionExpiresAt?.isAfter(DateTime.now()) == true;

  List<LoomSupportChoice> get choices {
    final values = actionPayload['choices'];
    if (values is! List) return const [];
    return values
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .where((value) => value['id'] is String && value['label'] is String)
        .map(
          (value) => LoomSupportChoice(
            id: value['id'] as String,
            label: value['label'] as String,
          ),
        )
        .toList();
  }

  bool get isSupportedAction => switch (actionKind) {
    'choice_v1' =>
      actionPayload.keys.every((key) => key == 'prompt' || key == 'choices') &&
          actionPayload['prompt'] is String &&
          (actionPayload['prompt'] as String).trim().isNotEmpty &&
          choices.length >= 2 &&
          choices.length <= 5,
    'request_diagnostics_v1' ||
    'refresh_subscription_v1' => actionPayload.isEmpty,
    'open_screen_v1' =>
      actionPayload.length == 1 &&
          const {
            'home',
            'routes',
            'statistics',
            'settings',
            'split_tunneling',
            'support',
          }.contains(actionPayload['screen']),
    _ => false,
  };
}

class LoomSupportClient {
  final String platform;
  final String appVersion;
  final Dio _dio;
  LoomSupportCredential? _credential;

  LoomSupportClient({
    required this.platform,
    required this.appVersion,
    Dio? dio,
  }) : _dio = dio ?? _createSupportDio();

  LoomSupportCredential? get credential => _credential;

  Future<LoomSupportCredential> ensureOpenThread() async {
    final credential = await _loadCredential();
    final thread = await _withBearer(
      (token) => _dio.get<Object?>(_url('thread'), options: _options(token)),
    );
    if (thread.data == null) {
      await _withBearer(
        (token) => _dio.post<Object?>(_url('thread'), options: _options(token)),
      );
    }
    return _credential ?? credential;
  }

  Future<List<LoomSupportMessage>> listMessages({required int afterId}) async {
    final response = await _withBearer(
      (token) => _dio.get<Object?>(
        _url('thread/messages'),
        queryParameters: {'after_id': afterId, 'limit': 100},
        options: _options(token),
      ),
      openThreadOnReauth: true,
    );
    final data = response.data;
    if (data is! List) throw const FormatException('invalid message list');
    return data
        .map((value) => LoomSupportMessage.fromJson(_map(value)))
        .toList();
  }

  Future<LoomSupportMessage> postText(String text) async {
    final response = await _withBearer(
      (token) => _dio.post<Object?>(
        _url('thread/messages'),
        data: {'message_id': utils.uuidV4, 'text': text},
        options: _options(token),
      ),
      openThreadOnReauth: true,
    );
    return LoomSupportMessage.fromJson(_map(response.data));
  }

  Future<LoomSupportMessage> respondToAction(
    int messageId, {
    required bool accept,
    String? choiceId,
  }) async {
    final response = await _withBearer(
      (token) => _dio.post<Object?>(
        _url('thread/actions/$messageId/respond'),
        data: {
          'decision': accept ? 'accept' : 'decline',
          'choice_id': ?choiceId,
        },
        options: _options(token),
      ),
      openThreadOnReauth: true,
    );
    return LoomSupportMessage.fromJson(_map(response.data));
  }

  String _url(String suffix) =>
      loomSupportApiUri.resolve('$_supportPath/$suffix').toString();

  Options _options(String token) => Options(
    headers: {'Authorization': 'Bearer $token'},
    sendTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  );

  Future<Response<Object?>> _withBearer(
    Future<Response<Object?>> Function(String token) action, {
    bool openThreadOnReauth = false,
  }) async {
    var credential = await _loadCredential();
    try {
      return await action(credential.bearerToken);
    } on DioException catch (error) {
      if (error.response?.statusCode != 401) rethrow;
      await _clearCredential();
      credential = await _bootstrap();
      if (openThreadOnReauth) {
        await _dio.post<Object?>(
          _url('thread'),
          options: _options(credential.bearerToken),
        );
      }
      return action(credential.bearerToken);
    }
  }

  Future<LoomSupportCredential> _loadCredential() async {
    if (_credential != null) return _credential!;
    final stored = await preferences.getString(_credentialKey);
    if (stored != null) {
      try {
        _credential = LoomSupportCredential.fromJson(_map(jsonDecode(stored)));
        return _credential!;
      } catch (_) {
        await preferences.remove(_credentialKey);
      }
    }
    return _bootstrap();
  }

  Future<LoomSupportCredential> _bootstrap() async {
    final response = await _dio.post<Object?>(
      loomSupportApiUri.resolve('$_supportPath/bootstrap').toString(),
      data: {'platform': platform, 'app_version': appVersion},
      options: Options(
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    final credential = LoomSupportCredential.fromJson(_map(response.data));
    final saved = await preferences.setString(
      _credentialKey,
      jsonEncode(credential.toJson()),
    );
    if (!saved) throw StateError('support credential could not be persisted');
    _credential = credential;
    return credential;
  }

  Future<void> _clearCredential() async {
    _credential = null;
    await preferences.remove(_credentialKey);
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  throw const FormatException('expected JSON object');
}

Map<String, dynamic> _mapOrEmpty(Object? value) {
  if (value == null) return const {};
  return _map(value);
}

Dio _createSupportDio() {
  final dio = Dio(
    BaseOptions(
      headers: {'Accept': 'application/json'},
      connectTimeout: const Duration(seconds: 10),
    ),
  );
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient(
        context: SecurityContext(withTrustedRoots: true),
      );
      client.badCertificateCallback = null;
      client.findProxy = (_) => 'DIRECT';
      return client;
    },
  );
  return dio;
}
