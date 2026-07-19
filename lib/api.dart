import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Hermes 网关 API 服务器异常。
class ApiException implements Exception {
  ApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;
  final String? code;

  @override
  String toString() =>
      'ApiException($statusCode${code != null ? ', $code' : ''}): $message';
}

/// 一条 SSE 事件。event 缺省为 'message'。
class SseEvent {
  SseEvent(this.event, this.data);

  final String event;
  final String data;

  Map<String, dynamic> get json {
    if (data.isEmpty || data == '[DONE]') return <String, dynamic>{};
    final decoded = jsonDecode(data);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }
}

/// 将字节流解析为 SSE 事件流。
///
/// 兼容：命名事件（event: 行）、注释行（: 开头，如 keepalive /
/// `: stream closed`）、多行 data、[DONE] 哨兵（作为 data 原样透出，
/// 由调用方判断）。
/// 流结束时若最后一帧没有尾部空行，也会 flush 出来。
Stream<SseEvent> decodeSse(Stream<List<int>> bytes) async* {
  var buffer = '';
  var eventName = 'message';
  final dataLines = <String>[];

  SseEvent? dispatch() {
    if (dataLines.isEmpty) return null;
    return SseEvent(eventName, dataLines.join('\n'));
  }

  void applyField(String line) {
    if (line.startsWith(':')) return; // 注释 / keepalive
    if (line.startsWith('event:')) {
      eventName = line.substring(6).trim();
      return;
    }
    if (line.startsWith('data:')) {
      var value = line.substring(5);
      if (value.startsWith(' ')) value = value.substring(1);
      dataLines.add(value);
    }
  }

  await for (final chunk in bytes.transform(utf8.decoder)) {
    buffer += chunk;
    var idx = buffer.indexOf('\n');
    while (idx >= 0) {
      var line = buffer.substring(0, idx);
      buffer = buffer.substring(idx + 1);
      idx = buffer.indexOf('\n');
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty) {
        final event = dispatch();
        if (event != null) yield event;
        eventName = 'message';
        dataLines.clear();
        continue;
      }
      applyField(line);
    }
  }

  // 流末尾可能没有换行/空行分隔符；把残留 buffer 当作最后一行再 dispatch。
  if (buffer.isNotEmpty) {
    var line = buffer;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.isNotEmpty) applyField(line);
  }
  final tail = dispatch();
  if (tail != null) yield tail;
}

/// Hermes 网关 API 客户端（api_server 平台，默认端口 8642）。
///
/// 所有接口（除 /health 外）都需要 `Authorization: Bearer <API_SERVER_KEY>`。
class HermesApi {
  HermesApi({required this.baseUrl, required this.apiKey, http.Client? client})
      : _client = client ?? http.Client();

  String baseUrl;
  String apiKey;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Map<String, String> get _headers => <String, String>{
        'Authorization': 'Bearer $apiKey',
        'Accept': 'application/json',
      };

  static String _errorMessage(int status, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic> && err['message'] != null) {
          return err['message'].toString();
        }
        if (err is String) return err; // /api/jobs 的扁平错误格式
        if (decoded['message'] != null) return decoded['message'].toString();
      }
    } catch (_) {
      // 非 JSON 响应体，原样返回
    }
    return body.length > 300 ? body.substring(0, 300) : body;
  }

  static String? _errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic> && err['code'] != null) {
          return err['code'].toString();
        }
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    Map<String, String>? extraHeaders,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers.addAll(_headers);
    if (extraHeaders != null) request.headers.addAll(extraHeaders);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30), onTimeout: () {
      throw TimeoutException('请求超时: $method $path');
    });
    final text = await response.stream.bytesToString();
    if (response.statusCode >= 400) {
      throw ApiException(
        response.statusCode,
        _errorMessage(response.statusCode, text),
        code: _errorCode(text),
      );
    }
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'data': decoded};
  }

  /// POST 一个 SSE 端点并返回事件流。
  ///
  /// [onHeaders] 在响应头到达时回调（用于读取 X-Hermes-Session-Id）。
  Stream<SseEvent> postSse(
    String path, {
    Map<String, dynamic>? body,
    void Function(Map<String, String> headers)? onHeaders,
  }) async* {
    final request = http.Request('POST', _uri(path));
    request.headers.addAll(_headers);
    request.headers['Accept'] = 'text/event-stream';
    request.headers['Cache-Control'] = 'no-cache';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (e) {
      throw ApiException(-1, '连接失败: $e');
    }
    onHeaders?.call(response.headers);
    if (response.statusCode >= 400) {
      final text = await response.stream.bytesToString();
      throw ApiException(
        response.statusCode,
        _errorMessage(response.statusCode, text),
        code: _errorCode(text),
      );
    }
    yield* decodeSse(response.stream);
  }

  // ------------------------------------------------------------------
  // 健康 / 发现
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> health() => _send('GET', '/health');

  Future<Map<String, dynamic>> healthDetailed() =>
      _send('GET', '/health/detailed');

  Future<Map<String, dynamic>> capabilities() =>
      _send('GET', '/v1/capabilities');

  Future<List<dynamic>> models() async =>
      (await _send('GET', '/v1/models'))['data'] as List? ?? <dynamic>[];

  Future<List<dynamic>> skills() async =>
      (await _send('GET', '/v1/skills'))['data'] as List? ?? <dynamic>[];

  Future<List<dynamic>> toolsets() async =>
      (await _send('GET', '/v1/toolsets'))['data'] as List? ?? <dynamic>[];

  // ------------------------------------------------------------------
  // 会话
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> listSessions({int limit = 50, int offset = 0}) =>
      _send('GET', '/api/sessions',
          query: <String, String>{
            'limit': '$limit',
            'offset': '$offset',
          });

  Future<Map<String, dynamic>> createSession({
    String? title,
    String? model,
    String? systemPrompt,
  }) =>
      _send('POST', '/api/sessions', body: <String, dynamic>{
        if (title != null && title.isNotEmpty) 'title': title,
        if (model != null && model.isNotEmpty) 'model': model,
        if (systemPrompt != null && systemPrompt.isNotEmpty)
          'system_prompt': systemPrompt,
      });

  Future<Map<String, dynamic>> getSession(String id) =>
      _send('GET', '/api/sessions/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>> patchSession(String id,
          {String? title, String? endReason}) =>
      _send('PATCH', '/api/sessions/${Uri.encodeComponent(id)}',
          body: <String, dynamic>{
            if (title != null) 'title': title,
            if (endReason != null) 'end_reason': endReason,
          });

  Future<Map<String, dynamic>> deleteSession(String id) =>
      _send('DELETE', '/api/sessions/${Uri.encodeComponent(id)}');

  Future<List<dynamic>> sessionMessages(String id) async =>
      (await _send('GET', '/api/sessions/${Uri.encodeComponent(id)}/messages'))[
              'data'] as List? ??
          <dynamic>[];

  Future<Map<String, dynamic>> forkSession(String id, {String? title}) =>
      _send('POST', '/api/sessions/${Uri.encodeComponent(id)}/fork',
          body: <String, dynamic>{
            if (title != null && title.isNotEmpty) 'title': title,
          });

  /// 会话内流式对话。事件名：run.started / message.started /
  /// assistant.delta / tool.progress / tool.started / tool.completed /
  /// tool.failed / assistant.completed / run.completed / error / done。
  Stream<SseEvent> chatStream(
    String sessionId,
    String message, {
    void Function(Map<String, String> headers)? onHeaders,
  }) =>
      postSse('/api/sessions/${Uri.encodeComponent(sessionId)}/chat/stream',
          body: <String, dynamic>{'message': message}, onHeaders: onHeaders);

  // ------------------------------------------------------------------
  // Runs（一次性任务，支持审批）
  // ------------------------------------------------------------------

  Future<String> createRun({
    required String input,
    String? instructions,
    String? sessionId,
  }) async {
    final resp = await _send('POST', '/v1/runs', body: <String, dynamic>{
      'input': input,
      if (instructions != null && instructions.isNotEmpty)
        'instructions': instructions,
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
    });
    return resp['run_id'].toString();
  }

  Future<Map<String, dynamic>> getRun(String runId) =>
      _send('GET', '/v1/runs/${Uri.encodeComponent(runId)}');

  /// Run 事件流。事件类型在 JSON 的 "event" 字段内（无 event: 行）。
  Stream<SseEvent> runEvents(String runId) =>
      postSse('/v1/runs/${Uri.encodeComponent(runId)}/events');

  Future<Map<String, dynamic>> respondApproval(
    String runId,
    String choice, {
    bool all = false,
  }) =>
      _send('POST', '/v1/runs/${Uri.encodeComponent(runId)}/approval',
          body: <String, dynamic>{'choice': choice, 'all': all});

  Future<Map<String, dynamic>> stopRun(String runId) =>
      _send('POST', '/v1/runs/${Uri.encodeComponent(runId)}/stop');

  // ------------------------------------------------------------------
  // Jobs（定时任务）
  // ------------------------------------------------------------------

  Future<List<dynamic>> listJobs() async =>
      (await _send('GET', '/api/jobs',
              query: const <String, String>{'include_disabled': 'true'}))['jobs']
          as List? ??
      <dynamic>[];

  Future<Map<String, dynamic>> createJob({
    required String name,
    required String schedule,
    required String prompt,
    String? deliver,
  }) =>
      _send('POST', '/api/jobs', body: <String, dynamic>{
        'name': name,
        'schedule': schedule,
        'prompt': prompt,
        if (deliver != null && deliver.isNotEmpty) 'deliver': deliver,
      });

  Future<Map<String, dynamic>> updateJob(
          String id, Map<String, dynamic> fields) =>
      _send('PATCH', '/api/jobs/${Uri.encodeComponent(id)}', body: fields);

  Future<Map<String, dynamic>> deleteJob(String id) =>
      _send('DELETE', '/api/jobs/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>> jobAction(String id, String action) =>
      _send('POST', '/api/jobs/${Uri.encodeComponent(id)}/$action');
}
