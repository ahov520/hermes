import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Hermes Studio（hermes-web-ui，默认 8648）REST 客户端。
///
/// 登录：POST /api/auth/login {username,password} → {token}（JWT，约 30 天）。
/// 之后所有请求带 `Authorization: Bearer <token>`；401 时用保存的
/// 账号密码静默重登一次并重试。
class StudioApiException implements Exception {
  StudioApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'StudioApiException($statusCode): $message';
}

class StudioApi {
  StudioApi({
    required this.baseUrl,
    this.username,
    this.password,
    this.token,
    this.onToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  String baseUrl;
  String? username;
  String? password;
  String? token;

  /// token 变化（登录/静默重登）时回调，用于持久化。
  final void Function(String token)? onToken;
  final http.Client _client;

  bool _relogging = false;

  bool get isAuthed => token != null && token!.isNotEmpty;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Map<String, String> get _headers => <String, String>{
        if (isAuthed) 'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        // Cloudflare Bot Fight Mode 会拦截 dart:io 默认 UA（实测 403/1010）
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36 HermesMobile/1.0',
      };

  // ------------------------------------------------------------------
  // 认证
  // ------------------------------------------------------------------

  /// 公开的安装状态探测：{hasPasswordLogin, hasUsers}
  Future<Map<String, dynamic>> status() async {
    final resp = await _client
        .get(_uri('/api/auth/status'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    return _decode(resp);
  }

  /// 登录并保存 token；返回当前用户对象（me）。
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    final resp = await _client
        .post(
          _uri('/api/auth/login'),
          headers: <String, String>{
            ..._headers,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, String>{
            'username': username,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final body = _decode(resp);
    final t = body['token']?.toString();
    if (t == null || t.isEmpty) {
      throw StudioApiException(resp.statusCode, '登录响应缺少 token');
    }
    this.username = username;
    this.password = password;
    token = t;
    onToken?.call(t);
    return me();
  }

  Future<Map<String, dynamic>> me() => _send('GET', '/api/auth/me');

  Future<void> logout() async {
    token = null;
  }

  Future<bool> _tryRelogin() async {
    if (_relogging) return false;
    final u = username;
    final p = password;
    if (u == null || u.isEmpty || p == null || p.isEmpty) return false;
    _relogging = true;
    try {
      await login(username: u, password: p);
      return true;
    } catch (_) {
      return false;
    } finally {
      _relogging = false;
    }
  }

  // ------------------------------------------------------------------
  // 基础请求
  // ------------------------------------------------------------------

  Map<String, dynamic> _decode(http.Response resp) {
    final text = utf8.decode(resp.bodyBytes);
    if (resp.statusCode >= 400) {
      String message = text;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          final err = decoded['error'];
          if (err is String) {
            message = err;
          } else if (err is Map && err['message'] != null) {
            message = err['message'].toString();
          } else if (decoded['message'] != null) {
            message = decoded['message'].toString();
          }
        }
      } catch (_) {}
      throw StudioApiException(resp.statusCode,
          message.length > 300 ? message.substring(0, 300) : message);
    }
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'data': decoded};
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    bool retryOn401 = true,
  }) async {
    Future<http.Response> send() {
      final request = http.Request(method, _uri(path, query));
      request.headers.addAll(_headers);
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.bodyBytes = utf8.encode(jsonEncode(body));
      }
      return _client
          .send(request)
          .timeout(const Duration(seconds: 30))
          .then(http.Response.fromStream);
    }

    var resp = await send();
    if (resp.statusCode == 401 && retryOn401 && await _tryRelogin()) {
      resp = await send();
    }
    return _decode(resp);
  }

  // ------------------------------------------------------------------
  // 会话（Sessions）
  // ------------------------------------------------------------------

  /// 会话列表。返回 {sessions: [...]}（默认排除已归档）。
  Future<List<dynamic>> sessions({
    int limit = 500,
    String? source,
    bool includeArchived = false,
  }) async {
    final resp = await _send('GET', '/api/hermes/sessions', query: <String, String>{
      'limit': '$limit',
      if (source != null) 'source': source,
      if (includeArchived) 'include_archived': '1',
    });
    return resp['sessions'] as List? ?? resp['data'] as List? ?? <dynamic>[];
  }

  /// 会话消息（分页，全量字段）。返回 {session, messages, ...}
  Future<Map<String, dynamic>> sessionMessages(
    String sessionId, {
    int offset = 0,
    int limit = 150,
  }) =>
      _send(
        'GET',
        '/api/hermes/sessions/conversations/${Uri.encodeComponent(sessionId)}/messages/paginated',
        query: <String, String>{'offset': '$offset', 'limit': '$limit'},
      );

  Future<Map<String, dynamic>> renameSession(String id, String title) =>
      _send('POST', '/api/hermes/sessions/${Uri.encodeComponent(id)}/rename',
          body: <String, dynamic>{'title': title});

  Future<Map<String, dynamic>> archiveSession(String id, {bool archive = true}) =>
      _send('POST',
          '/api/hermes/sessions/${Uri.encodeComponent(id)}/${archive ? 'archive' : 'unarchive'}');

  Future<Map<String, dynamic>> deleteSession(String id) =>
      _send('DELETE', '/api/hermes/sessions/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>> setSessionModel(
    String id, {
    required String model,
    String? provider,
  }) =>
      _send('POST', '/api/hermes/sessions/${Uri.encodeComponent(id)}/model',
          body: <String, dynamic>{
            'model': model,
            if (provider != null) 'provider': provider,
          });

  // ------------------------------------------------------------------
  // 模型
  // ------------------------------------------------------------------

  /// {default, default_provider, groups: [{provider, models: [...]}], ...}
  Future<Map<String, dynamic>> availableModels() =>
      _send('GET', '/api/hermes/available-models');
}
