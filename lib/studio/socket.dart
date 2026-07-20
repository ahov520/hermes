import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Hermes Studio 聊天实时通道：Socket.IO `/chat-run` 命名空间。
///
/// 服务端事件（→客户端）：run.started / message.delta / reasoning.delta /
/// thinking.delta / reasoning.available / tool.started / tool.completed /
/// tool.failed / run.completed / run.failed / run.queued /
/// approval.requested / approval.resolved / usage.updated /
/// session.title.updated / abort.* / compression.*。
/// 客户端事件（→服务端）：run / abort / approval.respond / cancel_queued_run。
class ChatRunSocket {
  ChatRunSocket({
    required this.baseUrl,
    required this.token,
    this.profile,
    this.onAuthError,
  });

  final String baseUrl;
  final String token;
  final String? profile;

  /// 鉴权失败（token 过期等）回调。
  final void Function()? onAuthError;

  /// 连接状态（标题栏指示灯用）。
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);

  io.Socket? _socket;
  final Map<String, List<void Function(Map<String, dynamic>)>> _handlers =
      <String, List<void Function(Map<String, dynamic>)>>{};

  static const List<String> _events = <String>[
    'run.started',
    'run.queued',
    'run.completed',
    'run.failed',
    'message.delta',
    'reasoning.delta',
    'thinking.delta',
    'reasoning.available',
    'tool.started',
    'tool.completed',
    'tool.failed',
    'approval.requested',
    'approval.resolved',
    'usage.updated',
    'session.title.updated',
    'abort.started',
    'abort.completed',
    'compression.started',
    'compression.completed',
    'clarify.requested',
  ];

  void connect() {
    dispose();
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final socket = io.io(
      '$base/chat-run',
      io.OptionBuilder()
          .setTransports(<String>['websocket', 'polling'])
          .setAuth(<String, String>{'token': token})
          .setQuery(profile != null ? <String, String>{'profile': profile!} : <String, String>{})
          .enableForceNew()
          .build(),
    );
    _socket = socket;
    socket.onConnect((_) => connected.value = true);
    socket.onDisconnect((_) => connected.value = false);
    socket.onConnectError((Object? err) {
      connected.value = false;
      final text = err?.toString() ?? '';
      if (text.contains('Authentication') || text.contains('401')) {
        onAuthError?.call();
      }
    });
    socket.onError((Object? err) {
      final text = err?.toString() ?? '';
      if (text.contains('Authentication') || text.contains('401')) {
        onAuthError?.call();
      }
    });
    for (final event in _events) {
      socket.on(event, (Object? data) {
        final map = data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{'value': data};
        for (final handler in _handlers[event] ?? const []) {
          handler(map);
        }
      });
    }
  }

  void on(String event, void Function(Map<String, dynamic>) handler) {
    _handlers.putIfAbsent(event, () => <void Function(Map<String, dynamic>)>[])
        .add(handler);
  }

  void emit(String event, Map<String, dynamic> data) {
    _socket?.emit(event, data);
  }

  /// 发起一次对话运行。
  void run(Map<String, dynamic> payload) => emit('run', payload);

  /// 中断会话当前运行。
  void abort(String sessionId) =>
      emit('abort', <String, dynamic>{'session_id': sessionId});

  /// 响应审批。
  void approvalRespond({
    required String sessionId,
    required String approvalId,
    required String choice,
  }) =>
      emit('approval.respond', <String, dynamic>{
        'session_id': sessionId,
        'approval_id': approvalId,
        'choice': choice,
      });

  void dispose() {
    connected.value = false;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      for (final event in _events) {
        socket.off(event);
      }
      socket.dispose();
    }
  }
}
