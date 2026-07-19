import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../api.dart';
import '../models.dart';
import '../state.dart';

/// 聊天页：会话管理 + SSE 流式对话 + 工具调用过程展示。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.state});

  final AppState state;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _Msg {
  _Msg.user(this.text) : role = 'user';
  _Msg.assistant() : role = 'assistant';
  _Msg.tool(this.toolName, this.text) : role = 'tool';
  _Msg.thinking() : role = 'thinking';

  final String role;
  String? text;
  final StringBuffer buffer = StringBuffer();
  String? toolName;
  String status = 'done'; // tool: running | done | failed
  bool streaming = false;
  bool error = false;

  String get display => buffer.isNotEmpty ? buffer.toString() : (text ?? '');
}

class _ChatPageState extends State<ChatPage> {
  List<HermesSession> _sessions = <HermesSession>[];
  HermesSession? _current;
  final List<_Msg> _items = <_Msg>[];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<SseEvent>? _sub;
  bool _sending = false;
  bool _loadingSessions = false;
  bool _loadingMessages = false;

  HermesApi? get _api => widget.state.api;

  @override
  void initState() {
    super.initState();
    _refreshSessions();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 数据加载
  // ------------------------------------------------------------------

  Future<void> _refreshSessions() async {
    final api = _api;
    if (api == null || _loadingSessions) return;
    _loadingSessions = true;
    try {
      final resp = await api.listSessions(limit: 100);
      if (!mounted) return;
      final list = (resp['data'] as List? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(HermesSession.fromJson)
          .toList();
      setState(() {
        _sessions = list;
        if (_current != null && !list.any((s) => s.id == _current!.id)) {
          _current = null;
          _items.clear();
        }
      });
    } catch (e) {
      _toast('加载会话失败: $e');
    } finally {
      _loadingSessions = false;
    }
  }

  Future<void> _selectSession(HermesSession session) async {
    Navigator.of(context).maybePop(); // 关闭抽屉
    setState(() {
      _current = session;
      _items.clear();
      _loadingMessages = true;
    });
    final api = _api;
    if (api == null) return;
    try {
      final messages = await api.sessionMessages(session.id);
      if (!mounted || _current?.id != session.id) return;
      final items = <_Msg>[];
      for (final raw in messages) {
        if (raw is! Map<String, dynamic>) continue;
        final msg = ChatMessage.fromJson(raw);
        if (msg.role == 'system') continue;
        if (msg.role == 'user') {
          items.add(_Msg.user(msg.content));
        } else if (msg.role == 'tool') {
          items.add(_Msg.tool(msg.toolName ?? 'tool', msg.content));
        } else {
          final m = _Msg.assistant();
          m.text = msg.content;
          items.add(m);
        }
      }
      setState(() => _items
        ..clear()
        ..addAll(items));
      _jumpToBottom();
    } catch (e) {
      _toast('加载消息失败: $e');
    } finally {
      if (mounted) setState(() => _loadingMessages = false);
    }
  }

  Future<HermesSession?> _ensureSession(String firstMessage) async {
    if (_current != null) return _current;
    final api = _api;
    if (api == null) return null;
    final title =
        firstMessage.length > 24 ? '${firstMessage.substring(0, 24)}…' : firstMessage;
    final resp = await api.createSession(title: title);
    final sessionMap = resp['session'];
    if (sessionMap is! Map<String, dynamic>) {
      throw ApiException(-1, '创建会话返回异常');
    }
    final session = HermesSession.fromJson(sessionMap);
    await _refreshSessions();
    if (mounted) setState(() => _current = session);
    return session;
  }

  // ------------------------------------------------------------------
  // 发送 & 流式接收
  // ------------------------------------------------------------------

  Future<void> _send() async {
    final api = _api;
    final text = _input.text.trim();
    if (api == null || text.isEmpty || _sending) return;
    _input.clear();
    setState(() {
      _sending = true;
      _items.add(_Msg.user(text));
    });
    _jumpToBottom();

    _Msg? assistant;
    try {
      final session = await _ensureSession(text);
      if (session == null) throw ApiException(-1, '无可用会话');
      assistant = _Msg.assistant()..streaming = true;
      setState(() => _items.add(assistant!));
      _jumpToBottom();

      final stream = api.chatStream(
        session.id,
        text,
        onHeaders: (headers) {
          // 压缩轮换后服务端会返回新的会话 id，跟随它
          final newId = headers['x-hermes-session-id'];
          if (newId != null &&
              newId.isNotEmpty &&
              _current != null &&
              newId != _current!.id) {
            _current = HermesSession(
              id: newId,
              title: _current!.title,
              model: _current!.model,
            );
          }
        },
      );

      _sub = stream.listen(
        (event) => _onStreamEvent(event, assistant!),
        onError: (Object e) {
          if (!mounted) return;
          setState(() {
            _sending = false;
            assistant!.streaming = false;
            assistant.error = true;
            assistant.buffer.write('\n\n[连接错误] $e');
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            _sending = false;
            assistant?.streaming = false;
          });
          _refreshSessions();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        assistant?.streaming = false;
        assistant?.error = true;
        assistant?.buffer.write('\n\n[错误] $e');
      });
    }
  }

  void _onStreamEvent(SseEvent event, _Msg assistant) {
    if (!mounted) return;
    final json = event.json;
    switch (event.event) {
      case 'assistant.delta':
        assistant.buffer.write(json['delta']?.toString() ?? '');
        break;
      case 'tool.progress':
        if (json['tool_name'] == '_thinking') {
          final delta = json['delta']?.toString() ?? '';
          if (delta.isNotEmpty) {
            var thinking = _lastOfRole('thinking');
            thinking ??= _append(_Msg.thinking());
            thinking.buffer.write(delta);
          }
        }
        break;
      case 'tool.started':
        _append(_Msg.tool(
          json['tool_name']?.toString() ?? 'tool',
          json['preview']?.toString() ?? '',
        )..status = 'running');
        break;
      case 'tool.completed':
      case 'tool.failed':
        final name = json['tool_name']?.toString();
        final tool = _lastRunningTool(name);
        if (tool != null) {
          tool.status = event.event == 'tool.failed' ? 'failed' : 'done';
          final preview = json['preview']?.toString();
          if (preview != null && preview.isNotEmpty) tool.text = preview;
        }
        break;
      case 'assistant.completed':
        final content = json['content']?.toString();
        if (content != null && content.isNotEmpty) {
          assistant.buffer
            ..clear()
            ..write(content);
        }
        break;
      case 'error':
        assistant.error = true;
        assistant.buffer.write('\n\n[错误] ${json['message'] ?? event.data}');
        break;
      case 'done':
      case 'run.started':
      case 'message.started':
      case 'run.completed':
      default:
        break;
    }
    setState(() {});
    _jumpToBottom();
  }

  _Msg _append(_Msg msg) {
    _items.add(msg);
    return msg;
  }

  _Msg? _lastOfRole(String role) {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].role == role) return _items[i];
    }
    return null;
  }

  _Msg? _lastRunningTool(String? name) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final m = _items[i];
      if (m.role == 'tool' && m.status == 'running') {
        if (name == null || m.toolName == name) return m;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------
  // 会话操作
  // ------------------------------------------------------------------

  Future<void> _newSession() async {
    setState(() {
      _current = null;
      _items.clear();
    });
    Navigator.of(context).maybePop();
  }

  Future<void> _renameSession() async {
    final api = _api;
    final session = _current;
    if (api == null || session == null) return;
    final controller = TextEditingController(text: session.title ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '会话标题'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    try {
      await api.patchSession(session.id, title: title.trim());
      await _refreshSessions();
      if (mounted) {
        setState(() => _current = _sessions.firstWhere(
              (s) => s.id == session.id,
              orElse: () => session,
            ));
      }
    } catch (e) {
      _toast('重命名失败: $e');
    }
  }

  Future<void> _forkSession() async {
    final api = _api;
    final session = _current;
    if (api == null || session == null) return;
    try {
      final resp = await api.forkSession(session.id);
      final forked = resp['session'];
      await _refreshSessions();
      if (forked is Map<String, dynamic> && mounted) {
        _toast('已分叉为新会话');
        await _selectSession(HermesSession.fromJson(forked));
      }
    } catch (e) {
      _toast('分叉失败: $e');
    }
  }

  Future<void> _deleteSession() async {
    final api = _api;
    final session = _current;
    if (api == null || session == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除「${session.displayTitle}」吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await api.deleteSession(session.id);
      setState(() {
        _current = null;
        _items.clear();
      });
      await _refreshSessions();
    } catch (e) {
      _toast('删除失败: $e');
    }
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    return Scaffold(
      appBar: AppBar(
        title: Text(_current?.displayTitle ?? 'Hermes 聊天'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '新会话',
            onPressed: api == null ? null : _newSession,
          ),
          if (_current != null)
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    _renameSession();
                  case 'fork':
                    _forkSession();
                  case 'delete':
                    _deleteSession();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'fork', child: Text('分叉会话')),
                PopupMenuItem(value: 'delete', child: Text('删除会话')),
              ],
            ),
        ],
      ),
      drawer: _buildDrawer(),
      body: api == null
          ? const Center(child: Text('请先在「设置」页配置服务器地址和 API Key'))
          : Column(
              children: [
                Expanded(child: _buildMessageList()),
                _buildInputBar(),
              ],
            ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: const Text('会话列表',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refreshSessions,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _sessions.isEmpty
                  ? const Center(child: Text('暂无会话，直接发消息即会创建'))
                  : ListView.builder(
                      itemCount: _sessions.length,
                      itemBuilder: (context, i) {
                        final s = _sessions[i];
                        return ListTile(
                          dense: true,
                          selected: s.id == _current?.id,
                          title: Text(s.displayTitle,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${formatUnixTs(s.lastActive ?? s.startedAt)} · ${s.messageCount} 条',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _selectSession(s),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList() {
    if (_loadingMessages) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          _current == null ? '输入消息开始新会话' : '暂无消息',
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: _items.length,
      itemBuilder: (context, i) => _buildItem(_items[i]),
    );
  }

  Widget _buildItem(_Msg msg) {
    final theme = Theme.of(context);
    switch (msg.role) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SelectableText(msg.text ?? ''),
          ),
        );
      case 'tool':
        final icon = switch (msg.status) {
          'running' => Icons.hourglass_top,
          'failed' => Icons.error_outline,
          _ => Icons.check_circle_outline,
        };
        final color = switch (msg.status) {
          'running' => theme.colorScheme.tertiary,
          'failed' => theme.colorScheme.error,
          _ => theme.colorScheme.primary,
        };
        return Container(
          margin: const EdgeInsets.only(right: 32, top: 2, bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${msg.toolName ?? 'tool'}'
                  '${(msg.text ?? '').isNotEmpty ? '\n${msg.text}' : ''}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      case 'thinking':
        return Container(
          margin: const EdgeInsets.only(right: 32, top: 2, bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            msg.display,
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: theme.hintColor,
            ),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
          ),
        );
      default: // assistant
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(right: 24, top: 4, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: msg.error
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (msg.display.isEmpty && msg.streaming)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  MarkdownBody(
                    data: msg.display,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                      p: theme.textTheme.bodyMedium,
                    ),
                  ),
                if (msg.streaming && msg.display.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Icon(Icons.more_horiz, size: 16),
                  ),
              ],
            ),
          ),
        );
    }
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '给 Hermes 发消息…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: const Icon(Icons.send),
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}
