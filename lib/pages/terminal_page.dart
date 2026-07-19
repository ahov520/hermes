import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../state.dart';

/// 终端页：伪终端。api_server 没有裸 shell 端点，
/// 命令通过 /v1/runs 由 agent 代执行，输出为 agent 原样返回的
/// stdout/stderr。每条命令独立执行（无持久 cwd/环境）。
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.state});

  final AppState state;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

/// 一条终端记录：提示行命令 + 输出 + 状态行（[exit: ok] 等）。
class _TermEntry {
  _TermEntry(this.command);

  final String command;
  final StringBuffer output = StringBuffer();
  final List<String> meta = <String>[];
}

class _TerminalPageState extends State<TerminalPage> {
  static const String _kHistoryKey = 'terminal_history';
  static const int _kHistoryMax = 50;

  /// 让 agent 只回传命令输出的指令。
  static const String _kShellInstructions =
      '你是一个 shell 执行器。只做一件事：用 terminal 工具执行用户给出的这条命令，'
      '然后把它的 stdout/stderr 原样返回，不要解释、不要追加任何评论。命令：';

  static const TextStyle _promptStyle = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: <String>['Consolas', 'Courier New'],
    fontSize: 13,
    height: 1.35,
    color: Color(0xFF4AF626), // 亮绿提示行
  );
  static const TextStyle _outputStyle = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: <String>['Consolas', 'Courier New'],
    fontSize: 13,
    height: 1.35,
    color: Color(0xFFD7FFD7), // 浅绿输出
  );
  static const TextStyle _metaStyle = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: <String>['Consolas', 'Courier New'],
    fontSize: 12,
    height: 1.35,
    color: Color(0xFF8A8A8A), // 灰色状态行
  );
  static const TextStyle _errorStyle = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: <String>['Consolas', 'Courier New'],
    fontSize: 12,
    height: 1.35,
    color: Color(0xFFFF6E67), // 红色失败行
  );
  static const TextStyle _approvalStyle = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: <String>['Consolas', 'Courier New'],
    fontSize: 12,
    height: 1.35,
    color: Color(0xFFFFC866), // 琥珀色审批提示
  );

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_TermEntry> _entries = <_TermEntry>[];
  StreamSubscription<SseEvent>? _sub;

  List<String> _history = <String>[];
  int _historyIndex = -1; // -1 表示未在翻阅历史
  String _savedInput = '';
  bool _running = false;
  bool _helpVisible = true;

  HermesApi? get _api => widget.state.api;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kHistoryKey);
    if (list != null && mounted) {
      setState(() => _history = list);
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kHistoryKey, _history);
  }

  void _addHistory(String cmd) {
    _history.remove(cmd); // 去重后放到最前
    _history.insert(0, cmd);
    if (_history.length > _kHistoryMax) {
      _history.removeRange(_kHistoryMax, _history.length);
    }
    _saveHistory();
  }

  Future<void> _execute(String raw) async {
    final api = _api;
    final cmd = raw.trim();
    if (api == null || cmd.isEmpty || _running) return;
    final entry = _TermEntry(cmd);
    setState(() {
      _running = true;
      _helpVisible = false;
      _entries.add(entry);
      _input.clear();
      _historyIndex = -1;
    });
    _addHistory(cmd);
    _jumpToBottom();
    try {
      final runId = await api.createRun(
        input: cmd,
        instructions: _kShellInstructions,
      );
      if (!mounted) return;
      _sub = api.runEvents(runId).listen(
        (event) => _onEvent(event, entry),
        onError: (Object e) {
          _appendMeta(entry, '[事件流中断: $e]');
          _finish();
        },
        onDone: _finish,
      );
    } catch (e) {
      _appendMeta(entry, '[提交失败: $e]');
      _finish();
    }
  }

  void _onEvent(SseEvent event, _TermEntry entry) {
    if (!mounted) return;
    final json = event.json;
    // runEvents 的事件类型在 JSON 的 event 字段内（无 event: 行）
    final type = event.event != 'message'
        ? event.event
        : (json['event']?.toString() ?? 'message');
    switch (type) {
      case 'message.delta':
        entry.output.write(json['delta']?.toString() ?? '');
        break;
      case 'run.completed':
        entry.output
          ..clear()
          ..write(json['output']?.toString() ?? '');
        entry.meta.add('[exit: ok]');
        _finish();
        break;
      case 'run.failed':
        entry.meta.add('[failed] ${json['error']?.toString() ?? '未知错误'}');
        _finish();
        break;
      case 'approval.request':
        entry.meta.add('[需要审批：请到「任务」页处理该命令的审批]');
        break;
      default:
        break;
    }
    setState(() {});
    _jumpToBottom();
  }

  void _appendMeta(_TermEntry entry, String line) {
    if (!mounted) return;
    setState(() => entry.meta.add(line));
    _jumpToBottom();
  }

  /// 结束当前执行（run 终态 / 流关闭 / 出错兜底）。
  void _finish() {
    _sub?.cancel();
    _sub = null;
    if (mounted) setState(() => _running = false);
  }

  void _historyUp() {
    if (_history.isEmpty) return;
    setState(() {
      if (_historyIndex < 0) {
        _savedInput = _input.text; // 暂存当前输入，按 ↓ 可恢复
        _historyIndex = 0;
      } else if (_historyIndex < _history.length - 1) {
        _historyIndex++;
      }
      _setInput(_history[_historyIndex]);
    });
  }

  void _historyDown() {
    if (_historyIndex < 0) return;
    setState(() {
      _historyIndex--;
      _setInput(_historyIndex < 0 ? _savedInput : _history[_historyIndex]);
    });
  }

  void _setInput(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _clear() {
    setState(_entries.clear);
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  TextStyle _metaStyleFor(String line) {
    if (line.startsWith('[failed]') ||
        line.startsWith('[提交失败') ||
        line.startsWith('[事件流中断')) {
      return _errorStyle;
    }
    if (line.startsWith('[需要审批')) return _approvalStyle;
    return _metaStyle;
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    return Scaffold(
      appBar: AppBar(title: const Text('终端')),
      backgroundColor: api == null ? null : const Color(0xFF0C0C0C),
      body: api == null
          ? const Center(child: Text('请先在「设置」页配置服务器地址和 API Key'))
          : SafeArea(
              child: Column(
                children: [
                  if (_helpVisible)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 10, 12, 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '每条命令独立执行（无持久 cwd/环境）；需要多步操作请用「聊天」页。',
                            style: _metaStyle,
                          ),
                          Text(
                            '输出为 agent 原样返回的 stdout/stderr。',
                            style: _metaStyle,
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: _entries.length,
                      itemBuilder: (context, i) => _buildEntry(_entries[i]),
                    ),
                  ),
                  _buildInputRow(),
                ],
              ),
            ),
    );
  }

  Widget _buildEntry(_TermEntry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('user@hermes:~\$ ${entry.command}',
              style: _promptStyle),
          if (entry.output.isNotEmpty)
            SelectableText(entry.output.toString(), style: _outputStyle),
          for (final line in entry.meta)
            Text(line, style: _metaStyleFor(line)),
        ],
      ),
    );
  }

  Widget _buildInputRow() {
    return Container(
      color: const Color(0xFF161616),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Text('~\$ ', style: _promptStyle),
          Expanded(
            child: TextField(
              controller: _input,
              style: _promptStyle,
              cursorColor: const Color(0xFF4AF626),
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.send,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '输入命令，回车执行',
                hintStyle: _metaStyle,
              ),
              onSubmitted: _execute,
            ),
          ),
          if (_running)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF4AF626),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.arrow_upward,
                size: 20, color: Color(0xFF4AF626)),
            tooltip: '上一条命令',
            visualDensity: VisualDensity.compact,
            onPressed: _historyUp,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_downward,
                size: 20, color: Color(0xFF4AF626)),
            tooltip: '下一条命令',
            visualDensity: VisualDensity.compact,
            onPressed: _historyDown,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined,
                size: 20, color: Color(0xFF4AF626)),
            tooltip: '清屏',
            visualDensity: VisualDensity.compact,
            onPressed: _clear,
          ),
        ],
      ),
    );
  }
}
