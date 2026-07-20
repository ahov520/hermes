import 'package:flutter/material.dart';

import '../api.dart';
import '../state.dart';

/// 技能页：浏览 agent 技能库（/v1/skills），按分类分组 + 搜索。
class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key, required this.state});

  final AppState state;

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  List<Map<String, dynamic>> _skills = <Map<String, dynamic>>[];
  bool _loading = false;
  String _query = '';

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
      final list = await api.skills();
      if (!mounted) return;
      setState(() {
        _skills = list.whereType<Map<String, dynamic>>().toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载技能失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final api = _api;
    final query = _query.trim().toLowerCase();
    final visible = _skills.where((s) {
      if (query.isEmpty) return true;
      return (s['name']?.toString().toLowerCase().contains(query) ?? false) ||
          (s['description']?.toString().toLowerCase().contains(query) ?? false);
    }).toList();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final s in visible) {
      final cat = s['category']?.toString();
      groups.putIfAbsent((cat == null || cat.isEmpty) ? '其他' : cat,
          () => <Map<String, dynamic>>[]).add(s);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('技能'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: api == null
          ? const Center(child: Text('请先在「设置」页配置服务器地址和 API Key'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: '搜索技能…',
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
                Expanded(
                  child: _loading && _skills.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : visible.isEmpty
                          ? Center(
                              child: Text(
                                _skills.isEmpty ? '暂无技能' : '没有匹配的技能',
                                style: TextStyle(color: theme.hintColor),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView(
                                children: [
                                  for (final entry in groups.entries) ...[
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 12, 16, 4),
                                      child: Text(
                                        '${entry.key}（${entry.value.length}）',
                                        style: theme.textTheme.labelMedium,
                                      ),
                                    ),
                                    for (final s in entry.value)
                                      Card(
                                        margin: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 3),
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                s['name']?.toString() ?? '?',
                                                style: theme
                                                    .textTheme.titleSmall,
                                              ),
                                              if ((s['description']
                                                      ?.toString() ??
                                                  '')
                                                  .isNotEmpty)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          top: 4),
                                                  child: Text(
                                                    s['description']
                                                        .toString(),
                                                    style: theme
                                                        .textTheme.bodySmall
                                                        ?.copyWith(
                                                            color: theme
                                                                .hintColor),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                ),
              ],
            ),
    );
  }
}
