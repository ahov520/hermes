import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../api.dart';
import '../models.dart';
import '../notifications.dart';
import '../state.dart';
import '../ui_feedback.dart';

/// 任务页：提交一次性 agent 任务（Run），实时查看事件流，
/// 处理工具审批（approval），可中断。
class RunsPage extends StatefulWidget {
  const RunsPage({super.key, required this.state});

  final AppState state;

  @override
  State<RunsPage> createState() => _RunsPageState();
}

class _RunsPageState extends State<RunsPage> {
  final TextEditingController _input = TextEditingController();
  final TextEditingController _instructions = TextEditingController();
  final List<RunRecord> _runs = <RunRecord>[];
  bool _submitting = false;
  bool _showInstructions = false;

  HermesApi? get _api => widget.state.api;

  @override
  void dispose() {
    _input.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final api = _api;
    final text = _input.text.trim();
    if (api == null || text.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final runId = await api.createRun(
        input: text,
        instructions: _instructions.text.trim(),
      );
      if (!mounted) return;
      final record = RunRecord(
        runId: runId,
        input: text,
        createdAt: DateTime.now(),
        status: 'running',
      );
      setState(() {
        _runs.insert(0, record);
        _input.clear();
      });
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => RunDetailPage(api: api, record: record),
      ));
      if (mounted) setState(() {}); // 回来后刷新状态
    } catch (e) {
      if (mounted) showErrorSnack(context, '提交失败: $e', onRetry: _submit);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 下拉刷新：逐个拉取进行中任务的最新状态。
  Future<void> _refreshRuns() async {
    final api = _api;
    if (api == null) return;
    for (final run in _runs.where((r) => r.isActive)) {
      try {
        final data = await api.getRun(run.runId);
        if (!mounted) return;
        final status = data['status']?.toString();
        if (status != null && status != run.status) {
          setState(() => run.status = status);
        }
      } catch (_) {
        // 单个任务刷新失败忽略（记录可能已被服务端清理）
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    return Scaffold(
      appBar: AppBar(title: const Text('任务')),
      body: api == null
          ? const Center(child: Text('请先在「设置」页配置服务器地址和 API Key'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: '描述一个任务，Hermes 将自主执行…',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      if (_showInstructions)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: TextField(
                            controller: _instructions,
                            minLines: 1,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              hintText: '附加指令（可选，作为临时系统提示）',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: () => setState(
                                () => _showInstructions = !_showInstructions),
                            icon: Icon(_showInstructions
                                ? Icons.expand_less
                                : Icons.expand_more),
                            label: const Text('附加指令'),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: _submitting ? null : _submit,
                            icon: const Icon(Icons.rocket_launch),
                            label: const Text('提交任务'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _runs.isEmpty
                      ? Center(
                          child: Text(
                            '本会话提交的任务会显示在这里\n（任务在服务端执行，可实时查看与审批）',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Theme.of(context).hintColor),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _refreshRuns,
                          child: ListView.builder(
                            itemCount: _runs.length,
                            itemBuilder: (context, i) {
                              final run = _runs[i];
                              return ListTile(
                                leading: _statusIcon(run.status),
                                title: Text(run.input,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle:
                                    Text('${run.runId} · ${run.status}'),
                                onTap: () async {
                                  await Navigator.of(context)
                                      .push(MaterialPageRoute<void>(
                                    builder: (_) => RunDetailPage(
                                        api: api, record: run),
                                  ));
                                  if (mounted) setState(() {});
                                },
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  static Widget _statusIcon(String status) {
    return switch (status) {
      'completed' => const Icon(Icons.check_circle, color: Colors.green),
      'failed' => const Icon(Icons.error, color: Colors.red),
      'cancelled' => const Icon(Icons.cancel, color: Colors.orange),
      'waiting_for_approval' =>
        const Icon(Icons.pending_actions, color: Colors.amber),
      _ => const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
    };
  }
}

/// 任务详情：SSE 事件流 + 审批 + 中断。
class RunDetailPage extends StatefulWidget {
  const RunDetailPage({super.key, required this.api, required this.record});

  final HermesApi api;
  final RunRecord record;

  @override
  State<RunDetailPage> createState() => _RunDetailPageState();
}

class _EventItem {
  _EventItem.text() : kind = 'text';
  _EventItem.tool(this.title, this.detail) : kind = 'tool';
  _EventItem.reason(this.detail) : kind = 'reason';
  _EventItem.notice(this.detail) : kind = 'notice';

  final String kind;
  final StringBuffer buffer = StringBuffer();
  String? title;
  String? detail;
  String status = 'done';

  String get display => buffer.isNotEmpty ? buffer.toString() : (detail ?? '');
}

class _Approval {
  _Approval({
    required this.command,
    required this.description,
    required this.choices,
  });

  final String command;
  final String description;
  final List<String> choices;
  bool pending = true;
  String? responded;
}

class _RunDetailPageState extends State<RunDetailPage> {
  final List<_EventItem> _events = <_EventItem>[];
  final List<_Approval> _approvals = <_Approval>[];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<SseEvent>? _sub;
  Timer? _poller;
  _EventItem? _textItem;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _poller = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _poller?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _subscribe() {
    _sub = widget.api.runEvents(widget.record.runId).listen(
      _onEvent,
      onError: (Object e) {
        // SSE 断开不致命，轮询兜底
        _addNotice('事件流中断（$e），已切换为轮询状态');
      },
    );
  }

  Future<void> _poll() async {
    if (!mounted || !widget.record.isActive) {
      _poller?.cancel();
      return;
    }
    try {
      final run = await widget.api.getRun(widget.record.runId);
      if (!mounted) return;
      final status = run['status']?.toString();
      if (status != null && status != widget.record.status) {
        setState(() => widget.record.status = status);
      }
      if (widget.record.status == 'completed' &&
          (run['output']?.toString().isNotEmpty ?? false) &&
          _textItem == null) {
        setState(() {
          _textItem = _EventItem.text()
            ..buffer.write(run['output'].toString());
          _events.insert(0, _textItem!);
        });
      }
    } catch (_) {
      // run 记录可能已被清理（TTL 1h），忽略
    }
  }

  void _onEvent(SseEvent event) {
    if (!mounted) return;
    final json = event.json;
    final type = event.event != 'message'
        ? event.event
        : (json['event']?.toString() ?? 'message');
    switch (type) {
      case 'message.delta':
        _textItem ??= _append(_EventItem.text());
        _textItem!.buffer.write(json['delta']?.toString() ?? '');
        break;
      case 'tool.started':
        _append(_EventItem.tool(
          json['tool']?.toString() ?? 'tool',
          json['preview']?.toString() ?? '',
        )..status = 'running');
        break;
      case 'tool.completed':
        final tool = _lastRunningTool();
        if (tool != null) {
          tool.status = json['error'] == true ? 'failed' : 'done';
        }
        break;
      case 'reasoning.available':
        final text = json['text']?.toString() ?? '';
        if (text.isNotEmpty) _append(_EventItem.reason(text));
        break;
      case 'approval.request':
        HapticFeedback.vibrate();
        final command = json['command']?.toString() ??
            json['description']?.toString() ??
            '';
        NotificationService.instance
            .runNeedsApproval(widget.record.runId, command);
        setState(() {
          widget.record.status = 'waiting_for_approval';
          _approvals.add(_Approval(
            command: command,
            description: json['description']?.toString() ?? '',
            choices: (json['choices'] as List? ??
                    <dynamic>['once', 'session', 'always', 'deny'])
                .map((e) => e.toString())
                .toList(),
          ));
        });
        break;
      case 'approval.responded':
        for (final a in _approvals.where((a) => a.pending)) {
          a.pending = false;
          a.responded = json['choice']?.toString();
        }
        if (widget.record.status == 'waiting_for_approval') {
          widget.record.status = 'running';
        }
        break;
      case 'run.completed':
        widget.record.status = 'completed';
        NotificationService.instance
            .runCompleted(widget.record.runId, widget.record.input);
        final output = json['output']?.toString() ?? '';
        if (output.isNotEmpty) {
          if (_textItem != null) {
            _textItem!.buffer
              ..clear()
              ..write(output);
          } else {
            _append(_EventItem.text()..buffer.write(output));
          }
        }
        _addNotice('任务完成');
        break;
      case 'run.failed':
        widget.record.status = 'failed';
        NotificationService.instance
            .runFailed(widget.record.runId, json['error']?.toString() ?? '');
        _addNotice('任务失败: ${json['error'] ?? '未知错误'}');
        break;
      case 'run.cancelled':
        widget.record.status = 'cancelled';
        _addNotice('任务已中断');
        break;
      default:
        break;
    }
    setState(() {});
    _jumpToBottom();
  }

  _EventItem _append(_EventItem item) {
    _events.add(item);
    return item;
  }

  _EventItem? _lastRunningTool() {
    for (var i = _events.length - 1; i >= 0; i--) {
      final e = _events[i];
      if (e.kind == 'tool' && e.status == 'running') return e;
    }
    return null;
  }

  void _addNotice(String text) {
    if (!mounted) return;
    setState(() => _events.add(_EventItem.notice(text)));
    _jumpToBottom();
  }

  Future<void> _respond(_Approval approval, String choice) async {
    try {
      await widget.api.respondApproval(widget.record.runId, choice);
      if (!mounted) return;
      setState(() {
        approval.pending = false;
        approval.responded = choice;
        if (widget.record.status == 'waiting_for_approval') {
          widget.record.status = 'running';
        }
      });
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(context, '审批响应失败: $e',
          onRetry: () => _respond(approval, choice));
    }
  }

  Future<void> _stop() async {
    try {
      await widget.api.stopRun(widget.record.runId);
      if (!mounted) return;
      setState(() => widget.record.status = 'stopping');
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(context, '中断失败: $e', onRetry: _stop);
    }
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
    final record = widget.record;
    return Scaffold(
      appBar: AppBar(
        title: Text('任务 ${record.status}'),
        actions: [
          if (record.isActive)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: '中断任务',
              onPressed: _stop,
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(12),
            child: Text(record.input,
                maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              children: [
                for (final e in _events) _buildEvent(e),
                for (final a in _approvals) _buildApproval(a),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEvent(_EventItem e) {
    final theme = Theme.of(context);
    switch (e.kind) {
      case 'tool':
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 3),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  e.status == 'running'
                      ? Icons.hourglass_top
                      : e.status == 'failed'
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${e.title}${(e.detail ?? '').isNotEmpty ? '\n${e.detail}' : ''}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      case 'reason':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            e.detail ?? '',
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: theme.hintColor,
            ),
          ),
        );
      case 'notice':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Center(
            child: Text(e.detail ?? '', style: theme.textTheme.labelMedium),
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MarkdownBody(data: e.display, selectable: true),
        );
    }
  }

  Widget _buildApproval(_Approval approval) {
    final theme = Theme.of(context);
    const choiceLabels = <String, String>{
      'once': '允许一次',
      'session': '本会话允许',
      'always': '总是允许',
      'deny': '拒绝',
    };
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
                Text('工具调用审批',
                    style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            if (approval.command.isNotEmpty)
              SelectableText(approval.command,
                  style: theme.textTheme.bodySmall),
            if (approval.description.isNotEmpty &&
                approval.description != approval.command)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(approval.description,
                    style: theme.textTheme.bodySmall),
              ),
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
                            child: Text(choiceLabels[c] ?? c),
                          )
                        : FilledButton.tonal(
                            onPressed: () => _respond(approval, c),
                            child: Text(choiceLabels[c] ?? c),
                          ),
                ],
              )
            else
              Text('已响应: ${choiceLabels[approval.responded] ?? approval.responded ?? '-'}',
                  style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
