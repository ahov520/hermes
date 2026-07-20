import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../state.dart';

/// 用量页：基于会话列表（/api/sessions）在客户端聚合 token 与费用。
/// 服务器无聚合统计端点，这里仿 Studio 用量页做本地计算。
class UsagePage extends StatefulWidget {
  const UsagePage({super.key, required this.state});

  final AppState state;

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  List<HermesSession>? _sessions;
  bool _loading = false;

  HermesApi? get _api => widget.state.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null || _loading) return;
    setState(() => _loading = true);
    try {
      final resp = await api.listSessions(limit: 200);
      if (!mounted) return;
      setState(() {
        _sessions = (resp['data'] as List? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(HermesSession.fromJson)
            .toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载用量失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final api = _api;
    return Scaffold(
      appBar: AppBar(
        title: const Text('用量'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: api == null
          ? const Center(child: Text('请先在「设置」页配置服务器地址和 API Key'))
          : _sessions == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _buildBody(theme),
                ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final sessions = _sessions!;
    if (sessions.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(child: Text('暂无会话数据')),
        ],
      );
    }
    // 汇总
    var totalInput = 0;
    var totalOutput = 0;
    var totalCost = 0.0;
    var costCount = 0;
    final byModel = <String, int>{};
    // 30 天每日输出
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final daily = List<int>.filled(30, 0);
    for (final s in sessions) {
      final input = s.inputTokens;
      final output = s.outputTokens;
      totalInput += input;
      totalOutput += output;
      final cost = s.costUsd;
      if (cost != null) {
        totalCost += cost;
        costCount++;
      }
      final model = (s.model == null || s.model!.isEmpty) ? '未知' : s.model!;
      byModel[model] = (byModel[model] ?? 0) + input + output;
      final ts = s.startedAt;
      if (ts != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
        final day = DateTime(dt.year, dt.month, dt.day);
        final idx = today.difference(day).inDays;
        if (idx >= 0 && idx < 30) daily[29 - idx] += output;
      }
    }
    final maxDaily = daily.fold<int>(1, (a, b) => a > b ? a : b);
    final modelEntries = byModel.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // 汇总卡片
        Row(
          children: [
            _statCard(theme, '会话', '${sessions.length}'),
            _statCard(theme, '输入 tokens', _fmtNum(totalInput)),
            _statCard(theme, '输出 tokens', _fmtNum(totalOutput)),
            _statCard(
              theme,
              '预估费用',
              costCount > 0 ? '\$${totalCost.toStringAsFixed(4)}' : '-',
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 30 天输出柱状图
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('近 30 天输出', style: theme.textTheme.titleSmall),
                const SizedBox(height: 12),
                SizedBox(
                  height: 110,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < 30; i++)
                        Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 1),
                            child: Tooltip(
                              message:
                                  '${today.subtract(Duration(days: 29 - i)).month}/${today.subtract(Duration(days: 29 - i)).day}: ${daily[i]}',
                              child: Container(
                                height: daily[i] == 0
                                    ? 2
                                    : (daily[i] / maxDaily * 100)
                                        .clamp(4.0, 100.0),
                                decoration: BoxDecoration(
                                  color: daily[i] == 0
                                      ? theme.colorScheme
                                          .surfaceContainerHighest
                                      : theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 按模型分布
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('按模型分布（tokens）', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final e in modelEntries.take(8))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(e.key,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        Expanded(
                          flex: 5,
                          child: LinearProgressIndicator(
                            value: modelEntries.first.value == 0
                                ? 0
                                : e.value / modelEntries.first.value,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(_fmtNum(e.value),
                            style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 会话明细（前 20 条）
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Text('最近会话', style: theme.textTheme.titleSmall),
              ),
              for (final s in sessions.take(20))
                ListTile(
                  dense: true,
                  title: Text(s.displayTitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(formatUnixTs(s.startedAt)),
                  trailing: Text(
                    '↑${s.inputTokens} ↓${s.outputTokens}',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statCard(ThemeData theme, String label, String value) {
    return Expanded(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Column(
            children: [
              Text(value,
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(label,
                  style: theme.textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtNum(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}
