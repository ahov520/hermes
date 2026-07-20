import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../state.dart';
import '../widgets/markdown_view.dart';
import 'api.dart';
import 'socket.dart';

/// Studio 会话条目（/api/hermes/sessions）。
class _SSession {
  _SSession({
    required this.id,
    this.source,
    this.title,
    this.preview,
    this.model,
    this.lastActive,
    this.messageCount = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.isActive = false,
  });

  factory _SSession.fromJson(Map<String, dynamic> json) => _SSession(
        id: (json['id'] ?? '').toString(),
        source: json['source']?.toString(),
        title: json['title']?.toString(),
        preview: json['preview']?.toString(),
        model: json['model']?.toString(),
        lastActive: (json['last_active'] as num?)?.toDouble() ??
            (json['started_at'] as num?)?.toDouble(),
        messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
        inputTokens: (json['input_tokens'] as num?)?.toInt() ?? 0,
        outputTokens: (json['output_tokens'] as num?)?.toInt() ?? 0,
        isActive: json['is_active'] == true,
      );

  final String id;
  final String? source;
  final String? title;
  final String? preview;
  final String? model;
  final double? lastActive;
  final int messageCount;
  final int inputTokens;
  final int outputTokens;
  final bool isActive;

  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    if (preview != null && preview!.isNotEmpty) return preview!;
    return id;
  }
}

class _Msg {
  _Msg.user(this.text, {this.imageBytes}) : role = 'user';
  _Msg.assistant() : role = 'assistant';
  _Msg.tool(this.toolName, this.text, {this.callId}) : role = 'tool';
  _Msg.thinking() : role = 'thinking';

  final String role;
  String? text;
  Uint8List? imageBytes;
  final StringBuffer buffer = StringBuffer();
  String? toolName;
  String? callId;
  String status = 'done'; // tool: running | done | failed
  bool streaming = false;
  bool error = false;
  bool expanded = false;

  String get display => buffer.isNotEmpty ? buffer.toString() : (text ?? '');
}

class _Approval {
  _Approval({required this.id, required this.command, required this.choices});

  final String id;
  final String command;
  final List<String> choices;
  bool pending = true;
  String? responded;
}

class _QuickCommand {
  const _QuickCommand(this.name, this.template, {this.isSlash = true});

  factory _QuickCommand.fromJson(Map<String, dynamic> json) => _QuickCommand(
        (json['name'] ?? '').toString(),
        (json['template'] ?? '').toString(),
        isSlash: false,
      );

  final String name;
  final String template;
  final bool isSlash; // true=Studio 斜杠指令（原文发送），false=自定义前缀模板

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'name': name, 'template': template};
}

/// Studio 对话页：Socket.IO 流式聊天 + 会话管理 + 审批 + 模型选择。
class StudioChatPage extends StatefulWidget {
  const StudioChatPage({super.key, required this.state});

  final AppState state;

  @override
  State<StudioChatPage> createState() => _StudioChatPageState();
}

class _StudioChatPageState extends State<StudioChatPage> {
  List<_SSession> _sessions = <_SSession>[];
  _SSession? _current;
  final List<_Msg> _items = <_Msg>[];
  final Set<_Msg> _appeared = <_Msg>{};
  final List<_Approval> _approvals = <_Approval>[];
  final TextEditingController _input = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  ChatRunSocket? _socket;
  String _socketSignature = ''; // baseUrl|token，账号切换时用于判断重连
  bool _running = false;
  bool _loadingSessions = false;
  bool _loadingMessages = false;
  String? _liveSessionId;
  String? _runId;
  Map<String, int>? _usage; // {input, output}
  Uint8List? _pendingImage;
  String _pendingImageMime = 'image/jpeg';

  // 模型选择
  Map<String, dynamic>? _models; // availableModels 响应
  String? _selectedModel;
  String? _selectedProvider;

  // 偏好
  String _sessionQuery = '';
  Set<String> _pinned = <String>{};
  List<_QuickCommand> _customCommands = <_QuickCommand>[];
  Timer? _draftDebounce;

  // Studio 斜杠指令（原文发送，服务端解释）
  static const List<String> _slashCommands = <String>[
    'usage', 'status', 'abort', 'queue', 'plan', 'learn', 'clear', 'title',
    'compress', 'fork', 'steer', 'destroy', 'moa', 'goal', 'model',
    'reloadMcp', 'reloadSkills', 'compact', 'verbose', 'thinking', 'help',
  ];

  StudioApi? get _api => widget.state.studio;

  String get _draftKey => 'draft_${_current?.id ?? 'new'}';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _connectSocket();
    _refreshSessions();
    _loadModels();
  }

  @override
  void didUpdateWidget(covariant StudioChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 账号切换（AppState 通知重建）后重连
    _connectSocket();
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _socket?.dispose();
    _input.dispose();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Socket
  // ------------------------------------------------------------------

  void _connectSocket() {
    final api = _api;
    if (api == null || !api.isAuthed) {
      _socket?.dispose();
      _socket = null;
      _socketSignature = '';
      return;
    }
    final signature = '${api.baseUrl}|${api.token}';
    if (_socket != null && _socketSignature == signature) return; // 已在用该账号连接
    _socket?.dispose();
    final socket = ChatRunSocket(
      baseUrl: api.baseUrl,
      token: api.token!,
      onAuthError: _relogin,
    );
    socket.on('message.delta', (d) {
      _captureSession(d);
      _assistant()?.buffer.write(d['delta']?.toString() ?? '');
      _tick();
    });
    socket.on('reasoning.delta', (d) => _thinkingDelta(d));
    socket.on('thinking.delta', (d) => _thinkingDelta(d));
    socket.on('reasoning.available', (d) {
      final text = d['text']?.toString() ?? '';
      if (text.isNotEmpty) {
        var t = _lastOfRole('thinking');
        t ??= _append(_Msg.thinking());
        t.buffer
          ..clear()
          ..write(text);
      }
      _tick();
    });
    socket.on('tool.started', (d) {
      _captureSession(d);
      _append(_Msg.tool(
        d['tool']?.toString() ?? d['name']?.toString() ?? 'tool',
        d['preview']?.toString() ?? d['arguments']?.toString() ?? '',
        callId: d['tool_call_id']?.toString(),
      )..status = 'running');
      _tick();
    });
    socket.on('tool.completed', (d) => _toolDone(d, 'done'));
    socket.on('tool.failed', (d) => _toolDone(d, 'failed'));
    socket.on('run.started', (d) {
      _captureSession(d);
      _runId = d['run_id']?.toString() ?? _runId;
      _tick();
    });
    socket.on('run.queued', (d) {
      _captureSession(d);
      final a = _assistant();
      if (a != null && a.buffer.isEmpty) a.buffer.write('排队中…');
      _tick();
    });
    socket.on('approval.requested', (d) {
      _captureSession(d);
      setState(() {
        _approvals.add(_Approval(
          id: d['approval_id']?.toString() ?? '',
          command: d['command']?.toString() ??
              d['description']?.toString() ??
              '',
          choices: (d['choices'] as List? ??
                  <dynamic>['once', 'session', 'always', 'deny'])
              .map((e) => e.toString())
              .toList(),
        ));
      });
      _jumpToBottom();
    });
    socket.on('approval.resolved', (d) {
      final id = d['approval_id']?.toString();
      setState(() {
        for (final a in _approvals.where((a) => a.pending)) {
          if (id == null || a.id == id) {
            a.pending = false;
            a.responded = d['choice']?.toString();
          }
        }
      });
    });
    socket.on('usage.updated', (d) {
      _captureSession(d);
      setState(() => _usage = <String, int>{
        'input': (d['input_tokens'] as num?)?.toInt() ?? 0,
        'output': (d['output_tokens'] as num?)?.toInt() ?? 0,
      });
    });
    socket.on('session.title.updated', (d) => _refreshSessions());
    socket.on('run.completed', (d) {
      _captureSession(d);
      final a = _assistant();
      final output = d['output']?.toString() ?? '';
      if (a != null && output.isNotEmpty) {
        a.buffer
          ..clear()
          ..write(output);
      }
      final usage = d['usage'];
      if (usage is Map) {
        _usage = <String, int>{
          'input': (usage['input_tokens'] as num?)?.toInt() ?? 0,
          'output': (usage['output_tokens'] as num?)?.toInt() ?? 0,
        };
      }
      _finishRun();
    });
    socket.on('run.failed', (d) {
      final a = _assistant();
      if (a != null) {
        a.error = true;
        a.buffer.write('\n\n[失败] ${d['error'] ?? '未知错误'}');
      }
      _finishRun();
    });
    socket.on('abort.completed', (d) {
      final a = _assistant();
      if (a != null) a.buffer.write('\n\n（已停止）');
      _finishRun();
    });
    socket.connect();
    if (mounted) {
      setState(() {
        _socket = socket;
        _socketSignature = signature;
      });
    }
  }

  void _thinkingDelta(Map<String, dynamic> d) {
    _captureSession(d);
    final delta = d['delta']?.toString() ?? '';
    if (delta.isNotEmpty) {
      var t = _lastOfRole('thinking');
      t ??= _append(_Msg.thinking());
      t.buffer.write(delta);
    }
    _tick();
  }

  void _toolDone(Map<String, dynamic> d, String status) {
    _captureSession(d);
    final callId = d['tool_call_id']?.toString();
    _Msg? tool;
    for (var i = _items.length - 1; i >= 0; i--) {
      final m = _items[i];
      if (m.role == 'tool' &&
          m.status == 'running' &&
          (callId == null || m.callId == callId || m.callId == null)) {
        tool = m;
        break;
      }
    }
    if (tool != null) {
      tool.status = status;
      final out = d['output']?.toString();
      if (out != null && out.isNotEmpty) tool.text = out;
    }
    _tick();
  }

  /// 从事件里捞 session_id（新会话首轮时服务端才分配）。
  void _captureSession(Map<String, dynamic> d) {
    final sid = d['session_id']?.toString();
    if (sid != null && sid.isNotEmpty && _liveSessionId == null) {
      _liveSessionId = sid;
    }
  }

  void _finishRun() {
    if (!mounted) return;
    setState(() {
      _running = false;
      _runId = null;
      final a = _assistant();
      a?.streaming = false;
    });
    _adoptLiveSession();
    _refreshSessions();
  }

  /// 首轮新会话：run 结束后把服务端分配的会话设为当前。
  Future<void> _adoptLiveSession() async {
    final sid = _liveSessionId;
    _liveSessionId = null;
    if (sid == null || _current != null) return;
    try {
      final list = await _api?.sessions(limit: 50);
      if (!mounted || list == null) return;
      for (final raw in list) {
        if (raw is Map<String, dynamic> && raw['id']?.toString() == sid) {
          setState(() => _current = _SSession.fromJson(raw));
          return;
        }
      }
    } catch (_) {}
  }

  Future<void> _relogin() async {
    final account = widget.state.activeStudioAccount;
    if (account.username.isEmpty) return;
    try {
      await widget.state.loginStudio(
        username: account.username,
        password: account.password,
      );
      _socket?.dispose();
      if (mounted) setState(() => _socket = null);
      _connectSocket();
    } catch (_) {}
  }

  _Msg? _assistant() {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].role == 'assistant') return _items[i];
    }
    return null;
  }

  _Msg? _lastOfRole(String role) {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].role == role) return _items[i];
    }
    return null;
  }

  _Msg _append(_Msg msg) {
    _items.add(msg);
    return msg;
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    _jumpToBottom();
  }

  // ------------------------------------------------------------------
  // 数据加载
  // ------------------------------------------------------------------

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final commands = <_QuickCommand>[];
    final raw = prefs.getString('quick_commands');
    if (raw != null && raw.isNotEmpty) {
      try {
        commands.addAll((jsonDecode(raw) as List)
            .whereType<Map<String, dynamic>>()
            .map(_QuickCommand.fromJson)
            .where((c) => c.name.isNotEmpty && c.template.isNotEmpty));
      } catch (_) {}
    }
    setState(() {
      _pinned =
          (prefs.getStringList('pinned_sessions') ?? const <String>[]).toSet();
      _customCommands = commands;
      final draft = prefs.getString('draft_new');
      if (_current == null && draft != null && draft.isNotEmpty) {
        _input.text = draft;
      }
    });
  }

  Future<void> _refreshSessions() async {
    final api = _api;
    if (api == null || !api.isAuthed || _loadingSessions) return;
    _loadingSessions = true;
    try {
      final list = await api.sessions(limit: 500);
      if (!mounted) return;
      setState(() {
        _sessions = list
            .whereType<Map<String, dynamic>>()
            .map(_SSession.fromJson)
            .toList();
        if (_current != null && !_sessions.any((s) => s.id == _current!.id)) {
          _current = null;
          _items.clear();
          _approvals.clear();
        }
      });
    } catch (e) {
      _toast('加载会话失败: $e');
    } finally {
      _loadingSessions = false;
    }
  }

  Future<void> _loadModels() async {
    final api = _api;
    if (api == null || !api.isAuthed) return;
    try {
      final models = await api.availableModels();
      if (mounted) setState(() => _models = models);
    } catch (_) {}
  }

  Future<void> _selectSession(_SSession session) async {
    Navigator.of(context).maybePop();
    setState(() {
      _current = session;
      _items.clear();
      _approvals.clear();
      _loadingMessages = true;
      _usage = session.inputTokens > 0 || session.outputTokens > 0
          ? <String, int>{
              'input': session.inputTokens,
              'output': session.outputTokens,
            }
          : null;
    });
    await _restoreDraft();
    final api = _api;
    if (api == null) return;
    try {
      final resp = await api.sessionMessages(session.id);
      if (!mounted || _current?.id != session.id) return;
      final items = <_Msg>[];
      final cardsByCallId = <String, _Msg>{};
      final messages = resp['messages'] as List? ?? <dynamic>[];
      for (final raw in messages) {
        if (raw is! Map<String, dynamic>) continue;
        final role = (raw['role'] ?? '').toString();
        if (role == 'system') continue;
        if (role == 'user') {
          items.add(_Msg.user(flattenContent(raw['content'])));
        } else if (role == 'tool') {
          final callId = raw['tool_call_id']?.toString();
          final content = flattenContent(raw['content']);
          final card = callId != null ? cardsByCallId[callId] : null;
          if (card != null) {
            card.text = content.isEmpty ? card.text : content;
          } else {
            items.add(_Msg.tool(raw['tool_name']?.toString() ?? 'tool', content,
                callId: callId));
          }
        } else {
          final reasoning = raw['reasoning_content']?.toString() ??
              raw['reasoning']?.toString() ??
              '';
          if (reasoning.isNotEmpty) {
            items.add(_Msg.thinking()..buffer.write(reasoning));
          }
          final m = _Msg.assistant();
          m.text = flattenContent(raw['content']);
          items.add(m);
          final toolCalls = raw['tool_calls'];
          if (toolCalls is List) {
            for (final tc in toolCalls) {
              if (tc is! Map) continue;
              final fn = tc['function'];
              final name = fn is Map ? fn['name']?.toString() : null;
              final args = fn is Map ? fn['arguments']?.toString() : null;
              final card = _Msg.tool(name ?? 'tool', args ?? '',
                  callId: tc['id']?.toString());
              items.add(card);
              final cid = tc['id']?.toString();
              if (cid != null) cardsByCallId[cid] = card;
            }
          }
        }
      }
      _appeared.addAll(items);
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

  // ------------------------------------------------------------------
  // 发送 / 停止 / 审批
  // ------------------------------------------------------------------

  void _send([String? textOverride]) {
    final socket = _socket;
    final api = _api;
    final text = (textOverride ?? _input.text).trim();
    final image = textOverride == null ? _pendingImage : null;
    final imageMime = _pendingImageMime;
    if (api == null || !api.isAuthed || socket == null) return;
    if (text.isEmpty && image == null) return;
    if (_running) return;
    if (textOverride == null) {
      _input.clear();
      _clearDraft();
    }
    setState(() {
      _running = true;
      _approvals.clear();
      if (textOverride == null) _pendingImage = null;
      _items.add(_Msg.user(text, imageBytes: image));
      _items.add(_Msg.assistant()..streaming = true);
    });
    _jumpToBottom();

    final Object input = image == null
        ? text
        : <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, dynamic>{
                'url': 'data:$imageMime;base64,${base64Encode(image)}',
              },
            },
            if (text.isNotEmpty)
              <String, dynamic>{'type': 'text', 'text': text},
          ];
    socket.run(<String, dynamic>{
      'input': input,
      if (_current != null) 'session_id': _current!.id,
      if (_selectedModel != null) 'model': _selectedModel,
      if (_selectedProvider != null) 'provider': _selectedProvider,
    });
  }

  void _stop() {
    final socket = _socket;
    final sid = _liveSessionId ?? _current?.id;
    if (socket == null || sid == null) return;
    socket.abort(sid);
  }

  void _respond(_Approval approval, String choice) {
    final socket = _socket;
    final sid = _liveSessionId ?? _current?.id;
    if (socket == null || sid == null) {
      _toast('无法响应：缺少会话上下文');
      return;
    }
    socket.approvalRespond(
      sessionId: sid,
      approvalId: approval.id,
      choice: choice,
    );
    setState(() {
      approval.pending = false;
      approval.responded = choice;
    });
  }

  void _regenerate() {
    if (_running) return;
    String? text;
    for (var i = _items.length - 1; i >= 0; i--) {
      final m = _items[i];
      if (m.role == 'user' && (m.text ?? '').isNotEmpty) {
        text = m.text;
        break;
      }
    }
    if (text == null) {
      _toast('没有可重发的用户消息');
      return;
    }
    _send(text);
  }

  // ------------------------------------------------------------------
  // 草稿 / 置顶 / 快捷指令
  // ------------------------------------------------------------------

  void _onInputChanged(String value) {
    _draftDebounce?.cancel();
    final key = _draftKey;
    _draftDebounce = Timer(const Duration(milliseconds: 300), () async {
      final prefs = await SharedPreferences.getInstance();
      if (value.trim().isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, value);
      }
    });
    setState(() {});
  }

  Future<void> _restoreDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final draft = prefs.getString(_draftKey) ?? '';
    if (!mounted) return;
    if (_input.text != draft) _input.text = draft;
  }

  Future<void> _clearDraft() async {
    _draftDebounce?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey);
  }

  Future<void> _togglePin(_SSession session) async {
    setState(() {
      if (!_pinned.remove(session.id)) {
        _pinned.add(session.id);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('pinned_sessions', _pinned.toList());
  }

  bool get _showCommandPanel => _input.text.startsWith('/');

  List<Object> get _matchingCommands {
    final query = _input.text.substring(1).trim().toLowerCase();
    final slash = _slashCommands.map((c) => _QuickCommand(c, '/$c'));
    final custom = _customCommands;
    if (query.isEmpty) return <Object>[...slash, ...custom];
    return <Object>[...slash, ...custom]
        .where((c) => c.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  void _applyCommand(_QuickCommand cmd) {
    final text = cmd.isSlash ? '${cmd.template} ' : cmd.template;
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onInputChanged(text);
  }

  Future<void> _saveCommands() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'quick_commands',
      jsonEncode(_customCommands.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> _addCommand() async {
    final nameCtrl = TextEditingController();
    final tplCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义指令'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称', hintText: '如：润色'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tplCtrl,
              decoration:
                  const InputDecoration(labelText: '模板', hintText: '如：请润色这段话：'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim().replaceAll('/', '');
    final template = tplCtrl.text.trim();
    if (name.isEmpty || template.isEmpty) {
      _toast('名称和模板不能为空');
      return;
    }
    setState(() =>
        _customCommands.add(_QuickCommand(name, template, isSlash: false)));
    await _saveCommands();
  }

  Future<void> _deleteCommand(_QuickCommand cmd) async {
    setState(() => _customCommands.remove(cmd));
    await _saveCommands();
    _toast('已删除自定义指令');
  }

  // ------------------------------------------------------------------
  // 会话操作
  // ------------------------------------------------------------------

  Future<void> _newSession() async {
    setState(() {
      _current = null;
      _items.clear();
      _approvals.clear();
      _usage = null;
    });
    await _restoreDraft();
    Navigator.of(context).maybePop();
  }

  Future<void> _renameSession(_SSession session) async {
    final api = _api;
    if (api == null) return;
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
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    try {
      await api.renameSession(session.id, title.trim());
      await _refreshSessions();
    } catch (e) {
      _toast('重命名失败: $e');
    }
  }

  Future<void> _archiveSession(_SSession session) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.archiveSession(session.id);
      _toast('已归档');
      if (_current?.id == session.id) {
        setState(() {
          _current = null;
          _items.clear();
          _approvals.clear();
        });
      }
      await _refreshSessions();
    } catch (e) {
      _toast('归档失败: $e');
    }
  }

  Future<void> _deleteSession(_SSession session) async {
    final api = _api;
    if (api == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除「${session.displayTitle}」吗？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
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
      if (_current?.id == session.id) {
        setState(() {
          _current = null;
          _items.clear();
          _approvals.clear();
        });
      }
      await _refreshSessions();
    } catch (e) {
      _toast('删除失败: $e');
    }
  }

  void _showSessionMenu(_SSession session, bool pinned) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(pinned ? '取消置顶' : '置顶会话'),
              onTap: () {
                Navigator.pop(sheetContext);
                _togglePin(session);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(sheetContext);
                _renameSession(session);
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('归档'),
              onTap: () {
                Navigator.pop(sheetContext);
                _archiveSession(session);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteSession(session);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // 图片
  // ------------------------------------------------------------------

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280, // Socket.IO maxPayload 1MB + 隧道限制，必须小图
        imageQuality: 70,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _pendingImage = bytes;
        _pendingImageMime = _mimeFromName(picked.name);
      });
    } catch (e) {
      _toast('选取图片失败: $e');
    }
  }

  static String _mimeFromName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' || 'heif' => 'image/heic',
      _ => 'image/jpeg',
    };
  }

  void _showImage(Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: InteractiveViewer(
            maxScale: 5.0,
            child: Center(child: Image.memory(bytes)),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // 模型选择
  // ------------------------------------------------------------------

  void _showModelPicker() {
    final models = _models;
    if (models == null) {
      _toast('模型列表未加载');
      return;
    }
    final groups = models['groups'];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: DraggableScrollableSheet(
          initialChildSize: 0.5,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) => ListView(
            controller: scrollController,
            children: [
              const ListTile(
                title: Text('选择模型',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              if (groups is List)
                for (final group in groups)
                  if (group is Map && group['models'] is List)
                    ...<Widget>[
                      ListTile(
                        dense: true,
                        title: Text(
                          '· ${group['provider'] ?? 'provider'}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      for (final m in group['models'] as List)
                        ListTile(
                          dense: true,
                          title: Text(_modelName(m)),
                          trailing: _modelName(m) == _selectedModel
                              ? const Icon(Icons.check, size: 18)
                              : null,
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _selectModel(_modelName(m),
                                group['provider']?.toString());
                          },
                        ),
                    ],
            ],
          ),
        ),
      ),
    );
  }

  static String _modelName(dynamic m) {
    if (m is Map) {
      return (m['id'] ?? m['name'] ?? m['model'] ?? m.toString()).toString();
    }
    return m.toString();
  }

  Future<void> _selectModel(String model, String? provider) async {
    setState(() {
      _selectedModel = model;
      _selectedProvider = provider;
    });
    final session = _current;
    final api = _api;
    if (session != null && api != null) {
      try {
        await api.setSessionModel(session.id, model: model, provider: provider);
        _toast('已切换模型: $model');
      } catch (e) {
        _toast('切换模型失败: $e');
      }
    } else {
      _toast('下一轮对话将使用: $model');
    }
  }

  // ------------------------------------------------------------------
  // 小部件
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

  static const Map<String, String> _choiceLabels = <String, String>{
    'once': '仅本次允许',
    'session': '本会话允许',
    'always': '始终允许',
    'deny': '拒绝',
  };

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final api = _api;
    final authed = api?.isAuthed ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            if (authed && _socket != null)
              ValueListenableBuilder<bool>(
                valueListenable: _socket!.connected,
                builder: (context, ok, _) => Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ok ? Colors.green : Colors.grey,
                  ),
                ),
              ),
            Flexible(
              child: Text(
                _current?.displayTitle ?? 'Hermes 对话',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_usage != null) ...[
              const SizedBox(width: 8),
              Text(
                '↑${_usage!['input']} ↓${_usage!['output']}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ],
        ),
        actions: [
          if (authed)
            IconButton(
              icon: const Icon(Icons.model_training),
              tooltip: '选择模型',
              onPressed: _showModelPicker,
            ),
          if (authed)
            IconButton(
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: '新会话',
              onPressed: _newSession,
            ),
        ],
      ),
      drawer: authed ? _buildDrawer() : null,
      body: !authed
          ? _buildLogin()
          : Column(
              children: [
                Expanded(child: _buildMessageList()),
                _buildInputBar(),
              ],
            ),
    );
  }

  /// 未登录：内嵌登录卡片。
  Widget _buildLogin() {
    final account = widget.state.activeStudioAccount;
    final userCtrl = TextEditingController(text: account.username);
    final passCtrl = TextEditingController(text: account.password);
    var busy = false;
    String? error;

    Future<void> login(void Function(void Function()) setCardState) async {
      setCardState(() {
        busy = true;
        error = null;
      });
      try {
        await widget.state.loginStudio(
          username: userCtrl.text.trim(),
          password: passCtrl.text,
        );
        // 登录成功后 AppState 通知重建，本页自动切换到聊天界面
      } catch (e) {
        setCardState(() {
          busy = false;
          error = e.toString();
        });
      }
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: StatefulBuilder(
          builder: (context, setCardState) => Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('登录 Hermes Studio',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(account.baseUrl,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                  TextField(
                    controller: userCtrl,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => login(setCardState),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed:
                        busy ? null : () => login(setCardState),
                    child: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('登录'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '服务器地址在「设置 → Studio 服务器」修改',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDrawer() {
    final theme = Theme.of(context);
    final query = _sessionQuery.trim().toLowerCase();
    final visible = _sessions.where((s) {
      if (query.isEmpty) return true;
      return s.displayTitle.toLowerCase().contains(query) ||
          (s.preview ?? '').toLowerCase().contains(query);
    }).toList();
    visible.sort((a, b) {
      final pa = _pinned.contains(a.id) ? 0 : 1;
      final pb = _pinned.contains(b.id) ? 0 : 1;
      if (pa != pb) return pa - pb;
      final aa = a.isActive ? 0 : 1;
      final ab = b.isActive ? 0 : 1;
      if (aa != ab) return aa - ab;
      return (b.lastActive ?? 0).compareTo(a.lastActive ?? 0);
    });
    // 按来源分组
    final groups = <String, List<_SSession>>{};
    for (final s in visible) {
      groups.putIfAbsent(_sourceLabel(s.source), () => <_SSession>[]).add(s);
    }
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: const Text('会话',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refreshSessions,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _sessionQuery = v),
                decoration: InputDecoration(
                  hintText: '搜索会话…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('暂无会话，直接发消息即会创建'))
                  : ListView(
                      children: [
                        for (final entry in groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                            child: Text(entry.key,
                                style: theme.textTheme.labelSmall),
                          ),
                          for (final s in entry.value)
                            ListTile(
                              dense: true,
                              selected: s.id == _current?.id,
                              leading: s.isActive
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : _pinned.contains(s.id)
                                      ? Icon(Icons.push_pin,
                                          size: 14,
                                          color: theme.colorScheme.primary)
                                      : null,
                              title: Text(s.displayTitle,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${formatUnixTs(s.lastActive)} · ${s.messageCount} 条'
                                '${s.model != null ? ' · ${s.model}' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _selectSession(s),
                              onLongPress: () => _showSessionMenu(
                                  s, _pinned.contains(s.id)),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _sourceLabel(String? source) {
    return switch (source) {
      'cli' => 'CLI',
      'api_server' => 'API',
      'coding_agent' => '编程工具',
      'global_agent' => '全局',
      'workflow' => '工作流',
      _ => '其他',
    };
  }

  Widget _buildMessageList() {
    if (_loadingMessages) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      if (_current == null) return _buildEmptyState();
      return Center(
        child: Text('暂无消息',
            style: TextStyle(color: Theme.of(context).hintColor)),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: _items.length + _approvals.length,
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return _buildApproval(_approvals[i - _items.length]);
        }
        return _buildItem(_items[i]);
      },
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    const suggestions = <String>[
      '帮我看看磁盘空间',
      '总结今天的新闻',
      '写一段 Python 快速排序',
      '定一个明早 9 点的提醒',
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome,
                size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('有什么可以帮你的？', style: theme.textTheme.titleLarge),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final s in suggestions)
                  ActionChip(label: Text(s), onPressed: () => _send(s)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(_Msg msg) {
    final child = _buildItemContent(msg);
    if (_appeared.contains(msg)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 200),
      onEnd: () => _appeared.add(msg),
      builder: (context, value, child) =>
          Opacity(opacity: value, child: child),
      child: child,
    );
  }

  Widget _buildItemContent(_Msg msg) {
    final theme = Theme.of(context);
    switch (msg.role) {
      case 'user':
        return GestureDetector(
          onLongPress: () => _showMessageMenu(msg),
          child: Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (msg.imageBytes != null)
                    Padding(
                      padding: EdgeInsets.only(
                          bottom: (msg.text ?? '').isEmpty ? 0 : 6),
                      child: GestureDetector(
                        onTap: () => _showImage(msg.imageBytes!),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(msg.imageBytes!,
                              height: 180, fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  if ((msg.text ?? '').isNotEmpty) SelectableText(msg.text!),
                ],
              ),
            ),
          ),
        );
      case 'tool':
        return Container(
          margin: const EdgeInsets.only(right: 24, top: 2, bottom: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 10),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            shape: const RoundedRectangleBorder(),
            collapsedShape: const RoundedRectangleBorder(),
            leading: Icon(_toolIcon(msg.toolName),
                size: 18, color: theme.colorScheme.primary),
            title: Row(
              children: [
                Expanded(
                  child: Text(msg.toolName ?? 'tool',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _toolStatus(msg, theme),
                ),
              ],
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: (msg.text ?? '').isNotEmpty
                    ? SelectableText(
                        msg.text!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontFamily: 'monospace'),
                      )
                    : Text('（无输出）',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor)),
              ),
            ],
          ),
        );
      case 'thinking':
        return Container(
          margin: const EdgeInsets.only(right: 32, top: 2, bottom: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => msg.expanded = !msg.expanded),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        msg.expanded ? Icons.expand_less : Icons.expand_more,
                        size: 14,
                        color: theme.hintColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        msg.expanded ? '思考过程（点击收起）' : '思考过程（点击展开）',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topLeft,
                child: msg.expanded
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                        child: Text(
                          msg.display,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: theme.hintColor,
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        );
      default: // assistant
        return GestureDetector(
          onLongPress: () => _showMessageMenu(msg),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: theme.colorScheme.primary,
                    child: Icon(Icons.auto_awesome,
                        size: 15, color: theme.colorScheme.onPrimary),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    margin:
                        const EdgeInsets.only(right: 24, top: 4, bottom: 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: msg.error
                          ? theme.colorScheme.errorContainer
                          : theme.colorScheme.secondaryContainer,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(16),
                      ),
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
                          MarkdownView(data: msg.display),
                        if (msg.streaming && msg.display.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Icon(Icons.more_horiz, size: 16),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
    }
  }

  Widget _buildApproval(_Approval approval) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.gpp_maybe_outlined),
                const SizedBox(width: 8),
                Text('工具调用审批', style: theme.textTheme.titleSmall),
              ],
            ),
            if (approval.command.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(approval.command,
                  style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            if (approval.pending)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final c in approval.choices)
                    c == 'deny'
                        ? OutlinedButton(
                            onPressed: () => _respond(approval, c),
                            child: Text(_choiceLabels[c] ?? c),
                          )
                        : FilledButton.tonal(
                            onPressed: () => _respond(approval, c),
                            child: Text(_choiceLabels[c] ?? c),
                          ),
                ],
              )
            else
              Text(
                '已响应: ${_choiceLabels[approval.responded] ?? approval.responded ?? '-'}',
                style: theme.textTheme.labelMedium,
              ),
          ],
        ),
      ),
    );
  }

  void _showMessageMenu(_Msg msg) {
    final canRegenerate = msg.role == 'assistant' &&
        !msg.streaming &&
        identical(_assistant(), msg) &&
        !_running;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制'),
              enabled: msg.display.isNotEmpty,
              onTap: () {
                Navigator.pop(sheetContext);
                Clipboard.setData(ClipboardData(text: msg.display));
                _toast('已复制到剪贴板');
              },
            ),
            if (canRegenerate)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('重新生成'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _regenerate();
                },
              ),
          ],
        ),
      ),
    );
  }

  static IconData _toolIcon(String? toolName) {
    final n = (toolName ?? '').toLowerCase();
    if (n.contains('terminal') || n.contains('shell')) return Icons.terminal;
    if (n.contains('web') || n.contains('search')) return Icons.travel_explore;
    if (n.contains('file') || n.contains('read') || n.contains('write')) {
      return Icons.description_outlined;
    }
    return Icons.build_outlined;
  }

  static Widget _toolStatus(_Msg msg, ThemeData theme) {
    switch (msg.status) {
      case 'running':
        return const SizedBox(
          key: ValueKey<String>('running'),
          width: 15,
          height: 15,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case 'failed':
        return Icon(
          Icons.close,
          key: const ValueKey<String>('failed'),
          size: 16,
          color: theme.colorScheme.error,
        );
      default:
        return const Icon(
          Icons.check,
          key: ValueKey<String>('done'),
          size: 16,
          color: Colors.green,
        );
    }
  }

  Widget _buildInputBar() {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showCommandPanel) _buildCommandPanel(),
            if (_pendingImage != null)
              Container(
                alignment: Alignment.centerLeft,
                margin: const EdgeInsets.only(bottom: 6),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(_pendingImage!,
                          height: 72, fit: BoxFit.cover),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: GestureDetector(
                        onTap: () => setState(() => _pendingImage = null),
                        child: const Icon(Icons.cancel, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  tooltip: '发送图片',
                  onPressed: _running ? null : _pickImage,
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onChanged: _onInputChanged,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: '给 Hermes 发消息…（/ 打开指令）',
                      isDense: true,
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: Icon(
                      _running ? Icons.stop_circle_outlined : Icons.send),
                  tooltip: _running ? '停止生成' : '发送',
                  style: _running
                      ? IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        )
                      : null,
                  onPressed: _running ? _stop : _send,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandPanel() {
    final theme = Theme.of(context);
    final commands = _matchingCommands;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final cmd in commands)
            if (cmd is _QuickCommand)
              ListTile(
                dense: true,
                title: Text(cmd.isSlash ? cmd.template : '/${cmd.name}'),
                subtitle: cmd.isSlash
                    ? null
                    : Text(cmd.template,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _applyCommand(cmd),
                onLongPress: !cmd.isSlash && _customCommands.contains(cmd)
                    ? () => _deleteCommand(cmd)
                    : null,
              ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.add, size: 18),
            title: const Text('自定义指令'),
            onTap: _addCommand,
          ),
        ],
      ),
    );
  }
}
