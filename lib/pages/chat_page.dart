import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../state.dart';
import '../widgets/markdown_view.dart';

/// 聊天页：会话管理 + SSE 流式对话 + 工具调用过程展示。
///
/// 另含：会话搜索/置顶、输入草稿、快捷指令、停止生成、
/// 长按消息菜单（复制/重新生成）、连接状态灯、图片全屏查看。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.state});

  final AppState state;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _Msg {
  _Msg.user(this.text, {this.imageBytes}) : role = 'user';
  _Msg.assistant() : role = 'assistant';
  _Msg.tool(this.toolName, this.text) : role = 'tool';
  _Msg.thinking() : role = 'thinking';

  final String role;
  String? text;
  Uint8List? imageBytes;
  final StringBuffer buffer = StringBuffer();
  String? toolName;
  String status = 'done'; // tool: running | done | failed
  bool streaming = false;
  bool error = false;
  bool expanded = false; // thinking: 思考过程是否展开

  String get display => buffer.isNotEmpty ? buffer.toString() : (text ?? '');
}

/// 输入框快捷指令（输入 '/' 触发面板）。
class _QuickCommand {
  const _QuickCommand(this.name, this.template);

  factory _QuickCommand.fromJson(Map<String, dynamic> json) => _QuickCommand(
        (json['name'] ?? '').toString(),
        (json['template'] ?? '').toString(),
      );

  final String name;
  final String template;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'name': name, 'template': template};
}

class _ChatPageState extends State<ChatPage> {
  List<HermesSession> _sessions = <HermesSession>[];
  HermesSession? _current;
  final List<_Msg> _items = <_Msg>[];
  final Set<_Msg> _appeared = <_Msg>{}; // 已完成淡入动画的消息
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<SseEvent>? _sub;
  bool _sending = false;
  bool _loadingSessions = false;
  bool _loadingMessages = false;
  Uint8List? _pendingImage;
  String _pendingImageMime = 'image/jpeg';

  // 会话搜索 / 置顶
  final TextEditingController _searchCtrl = TextEditingController();
  String _sessionQuery = '';
  Set<String> _pinned = <String>{};

  // 快捷指令（默认预设 + 用户自定义）
  static const List<_QuickCommand> _defaultCommands = <_QuickCommand>[
    _QuickCommand('总结', '请总结：'),
    _QuickCommand('翻译', '请翻译成中文：'),
    _QuickCommand('解释', '请解释这段内容：'),
  ];
  List<_QuickCommand> _customCommands = <_QuickCommand>[];

  // 输入草稿防抖
  Timer? _draftDebounce;

  // 连接状态灯
  Timer? _healthTimer;
  bool? _connOk;
  bool _checkingHealth = false;

  HermesApi? get _api => widget.state.api;

  /// 当前会话的草稿 key（无会话时用 draft_new）。
  String get _draftKey => 'draft_${_current?.id ?? 'new'}';

  @override
  void initState() {
    super.initState();
    _refreshSessions();
    _loadPrefs();
    _syncHealthTimer();
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 连接配置可能已切换（AppState 通知后父级会重建本页）
    _syncHealthTimer();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _draftDebounce?.cancel();
    _sub?.cancel();
    _searchCtrl.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 偏好加载（置顶 / 快捷指令 / 草稿）
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
      } catch (_) {
        // 数据损坏则忽略
      }
    }
    setState(() {
      _pinned =
          (prefs.getStringList('pinned_sessions') ?? const <String>[]).toSet();
      _customCommands = commands;
      // 启动时恢复「新会话」草稿
      final draft = prefs.getString('draft_new');
      if (_current == null && draft != null && draft.isNotEmpty) {
        _input.text = draft;
      }
    });
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
    await _restoreDraft();
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
      _appeared.addAll(items); // 历史消息不做淡入动画
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
    final current = _current;
    if (current != null && current.endReason == null) return current;
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

  /// 发送消息。[textOverride] 用于「重新生成」/建议项等直接指定文本的场景。
  Future<void> _send([String? textOverride]) async {
    final api = _api;
    final text = (textOverride ?? _input.text).trim();
    final image = textOverride == null ? _pendingImage : null;
    final imageMime = _pendingImageMime;
    if (api == null || (text.isEmpty && image == null) || _sending) return;
    if (textOverride == null) {
      _input.clear();
      _clearDraft();
    }
    setState(() {
      _sending = true;
      if (textOverride == null) _pendingImage = null;
      _items.add(_Msg.user(text, imageBytes: image));
    });
    _jumpToBottom();

    _Msg? assistant;
    try {
      final session = await _ensureSession(text.isEmpty ? '图片消息' : text);
      if (session == null) throw ApiException(-1, '无可用会话');
      assistant = _Msg.assistant()..streaming = true;
      setState(() => _items.add(assistant!));
      _jumpToBottom();

      final Object payload = image == null
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

      final stream = api.chatStream(
        session.id,
        payload,
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

  /// 停止当前生成：取消流订阅，并把助手消息标记为部分内容。
  void _stopSending() {
    if (!_sending) return;
    _sub?.cancel();
    _sub = null;
    final assistant = _lastOfRole('assistant');
    if (assistant != null && assistant.streaming) {
      assistant.streaming = false;
      if (assistant.buffer.isNotEmpty) {
        assistant.buffer.write('\n\n（已停止）');
      } else if ((assistant.text ?? '').isNotEmpty) {
        assistant.text = '${assistant.text!}\n\n（已停止）';
      } else {
        assistant.buffer.write('（已停止）');
      }
    }
    setState(() => _sending = false);
    _refreshSessions();
  }

  /// 重新生成：把最后一条用户消息原样重发一遍。
  void _regenerate() {
    if (_sending) return;
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
  // 输入草稿（按会话保存，300ms 防抖）
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
    setState(() {}); // 刷新快捷指令面板
  }

  Future<void> _restoreDraft() async {
    final key = _draftKey;
    final prefs = await SharedPreferences.getInstance();
    final draft = prefs.getString(key) ?? '';
    if (!mounted) return;
    if (_input.text != draft) _input.text = draft;
  }

  Future<void> _clearDraft() async {
    _draftDebounce?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey);
  }

  // ------------------------------------------------------------------
  // 会话置顶
  // ------------------------------------------------------------------

  Future<void> _togglePin(HermesSession session) async {
    setState(() {
      if (!_pinned.remove(session.id)) {
        _pinned.add(session.id);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('pinned_sessions', _pinned.toList());
  }

  /// 过滤 + 排序后的会话列表：搜索匹配 title/preview，置顶的排前面。
  List<HermesSession> get _visibleSessions {
    final q = _sessionQuery.trim().toLowerCase();
    final filtered = q.isEmpty
        ? List<HermesSession>.of(_sessions)
        : _sessions
            .where((s) =>
                s.displayTitle.toLowerCase().contains(q) ||
                (s.preview ?? '').toLowerCase().contains(q))
            .toList();
    // 分组而不是 sort，保证各自内部保持原有顺序
    final pinned = <HermesSession>[];
    final rest = <HermesSession>[];
    for (final s in filtered) {
      (_pinned.contains(s.id) ? pinned : rest).add(s);
    }
    return <HermesSession>[...pinned, ...rest];
  }

  // ------------------------------------------------------------------
  // 快捷指令
  // ------------------------------------------------------------------

  bool get _showCommandPanel => _input.text.startsWith('/');

  List<_QuickCommand> get _matchingCommands {
    final query = _input.text.substring(1).trim().toLowerCase();
    final all = <_QuickCommand>[..._defaultCommands, ..._customCommands];
    if (query.isEmpty) return all;
    return all
        .where((c) => c.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  /// 点选指令：把模板填入输入框，光标放到末尾。
  void _applyCommand(_QuickCommand cmd) {
    _input.value = TextEditingValue(
      text: cmd.template,
      selection: TextSelection.collapsed(offset: cmd.template.length),
    );
    _onInputChanged(cmd.template); // 存草稿并刷新面板
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
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '如：润色',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tplCtrl,
              decoration: const InputDecoration(
                labelText: '模板',
                hintText: '如：请润色这段话：',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
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
    setState(() => _customCommands.add(_QuickCommand(name, template)));
    await _saveCommands();
  }

  Future<void> _deleteCommand(_QuickCommand cmd) async {
    setState(() => _customCommands.remove(cmd));
    await _saveCommands();
    _toast('已删除自定义指令');
  }

  // ------------------------------------------------------------------
  // 连接状态灯
  // ------------------------------------------------------------------

  void _syncHealthTimer() {
    if (_api != null) {
      _healthTimer ??=
          Timer.periodic(const Duration(seconds: 30), (_) => _checkHealth());
      _checkHealth();
    } else if (_healthTimer != null) {
      _healthTimer?.cancel();
      _healthTimer = null;
      if (_connOk != null && mounted) setState(() => _connOk = null);
    }
  }

  Future<void> _checkHealth() async {
    final api = _api;
    if (api == null || _checkingHealth) return;
    _checkingHealth = true;
    bool ok;
    try {
      await api.health();
      ok = true;
    } catch (_) {
      ok = false;
    }
    _checkingHealth = false;
    if (mounted && ok != _connOk) setState(() => _connOk = ok);
  }

  // ------------------------------------------------------------------
  // 图片选择 / 全屏查看
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
        maxWidth: 1280, // 压缩图片，隧道上传防断连
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

  /// 全屏查看图片：黑底 + 双指缩放（最大 5 倍），点击关闭。
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
  // 会话操作
  // ------------------------------------------------------------------

  Future<void> _newSession() async {
    setState(() {
      _current = null;
      _items.clear();
    });
    await _restoreDraft();
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

  Future<void> _endSession() async {
    final api = _api;
    final session = _current;
    if (api == null || session == null) return;
    try {
      await api.patchSession(session.id, endReason: 'ended');
      _toast('会话已结束，下次发消息将开启新会话');
      await _refreshSessions();
      if (mounted) {
        setState(() => _current = _sessions.firstWhere(
              (s) => s.id == session.id,
              orElse: () => HermesSession(
                id: session.id,
                title: session.title,
                endReason: 'ended',
              ),
            ));
      }
    } catch (e) {
      _toast('结束会话失败: $e');
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
  // 消息长按菜单
  // ------------------------------------------------------------------

  void _showMessageMenu(_Msg msg) {
    // 仅最后一条助手消息提供「重新生成」
    final canRegenerate = msg.role == 'assistant' &&
        !msg.streaming &&
        identical(_lastOfRole('assistant'), msg);
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
        title: Row(
          children: [
            if (api != null && _connOk != null)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _connOk! ? Colors.green : Colors.grey,
                ),
              ),
            Flexible(
              child: Text(
                _current?.displayTitle ?? 'Hermes 聊天',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
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
                  case 'end':
                    _endSession();
                  case 'delete':
                    _deleteSession();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'fork', child: Text('分叉会话')),
                PopupMenuItem(value: 'end', child: Text('结束会话')),
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
    final theme = Theme.of(context);
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _sessionQuery = v),
                decoration: InputDecoration(
                  hintText: '搜索会话…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _sessionQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          tooltip: '清除',
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _sessionQuery = '');
                          },
                        ),
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
            Expanded(child: _buildSessionList()),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionList() {
    final theme = Theme.of(context);
    if (_sessions.isEmpty) {
      return const Center(child: Text('暂无会话，直接发消息即会创建'));
    }
    final visible = _visibleSessions;
    if (visible.isEmpty) {
      return const Center(child: Text('没有匹配的会话'));
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final s = visible[i];
        final pinned = _pinned.contains(s.id);
        return ListTile(
          dense: true,
          selected: s.id == _current?.id,
          title: Text(s.displayTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${formatUnixTs(s.lastActive ?? s.startedAt)} · ${s.messageCount} 条'
            '${s.endReason != null ? ' · 已结束' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: pinned
              ? Icon(Icons.push_pin,
                  size: 16, color: theme.colorScheme.primary)
              : null,
          onTap: () => _selectSession(s),
          onLongPress: () => _showPinMenu(s, pinned),
        );
      },
    );
  }

  void _showPinMenu(HermesSession session, bool pinned) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading:
                  Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(pinned ? '取消置顶' : '置顶会话'),
              onTap: () {
                Navigator.pop(sheetContext);
                _togglePin(session);
              },
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
      if (_current == null) return _buildEmptyState();
      return Center(
        child: Text(
          '暂无消息',
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

  /// 空状态：大图标 + 引导语 + 建议项。
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
                  ActionChip(
                    label: Text(s),
                    onPressed: () => _send(s),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(_Msg msg) {
    final child = _buildItemContent(msg);
    // 新消息淡入；已出现过的（含历史消息）直接返回，避免重建时重复动画
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                          child: Image.memory(
                            msg.imageBytes!,
                            height: 180,
                            fit: BoxFit.cover,
                          ),
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
            // 自定义 shape 去掉展开时的上下分隔线
            shape: const RoundedRectangleBorder(),
            collapsedShape: const RoundedRectangleBorder(),
            leading: Icon(
              _toolIcon(msg.toolName),
              size: 18,
              color: theme.colorScheme.primary,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    msg.toolName ?? 'tool',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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
                    : Text(
                        '（无输出）',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
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
                    child: Icon(
                      Icons.auto_awesome,
                      size: 15,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    margin: const EdgeInsets.only(right: 24, top: 4, bottom: 4),
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

  /// 按工具名挑图标。
  static IconData _toolIcon(String? toolName) {
    final n = (toolName ?? '').toLowerCase();
    if (n.contains('terminal') || n.contains('shell')) return Icons.terminal;
    if (n.contains('web') || n.contains('search')) return Icons.travel_explore;
    if (n.contains('file') || n.contains('read') || n.contains('write')) {
      return Icons.description_outlined;
    }
    return Icons.build_outlined;
  }

  /// 工具状态图标（配合 AnimatedSwitcher，用 key 区分状态）。
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
                      child: Image.memory(
                        _pendingImage!,
                        height: 72,
                        fit: BoxFit.cover,
                      ),
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
                  onPressed: _sending ? null : _pickImage,
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
                      hintText: '给 Hermes 发消息…',
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
                      _sending ? Icons.stop_circle_outlined : Icons.send),
                  tooltip: _sending ? '停止生成' : '发送',
                  style: _sending
                      ? IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        )
                      : null,
                  onPressed: _sending ? _stopSending : _send,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// '/' 快捷指令面板（输入栏上方，限高）。
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
            ListTile(
              dense: true,
              title: Text('/${cmd.name}'),
              subtitle: Text(
                cmd.template,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _applyCommand(cmd),
              // 长按删除自定义指令（预设不可删）
              onLongPress: _customCommands.contains(cmd)
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
