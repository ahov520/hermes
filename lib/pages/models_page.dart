import 'package:flutter/material.dart';

import '../api.dart';
import '../state.dart';

/// 模型页：可用模型（含路由别名）、工具集、API 能力清单。
class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key, required this.state});

  final AppState state;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  List<dynamic> _models = <dynamic>[];
  List<dynamic> _toolsets = <dynamic>[];
  Map<String, dynamic>? _capabilities;
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
      final results = await Future.wait<dynamic>([
        api.models(),
        api.toolsets(),
        api.capabilities(),
      ]);
      if (!mounted) return;
      setState(() {
        _models = results[0] as List<dynamic>;
        _toolsets = results[1] as List<dynamic>;
        _capabilities = results[2] as Map<String, dynamic>;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败: $e')));
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
        title: const Text('模型'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: api == null
          ? const Center(child: Text('请先在「设置」页配置服务器地址和 API Key'))
          : _loading && _models.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      _sectionTitle(theme, '模型（${_models.length}）'),
                      for (final m in _models)
                        if (m is Map) _buildModelTile(m, theme),
                      _sectionTitle(theme, '工具集（${_toolsets.length}）'),
                      for (final t in _toolsets)
                        if (t is Map) _buildToolsetTile(t, theme),
                      if (_capabilities != null) ...[
                        _sectionTitle(theme, 'API 能力'),
                        _buildCapabilities(theme),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(text, style: theme.textTheme.labelMedium),
    );
  }

  Widget _buildModelTile(Map<dynamic, dynamic> m, ThemeData theme) {
    final id = m['id']?.toString() ?? '?';
    final root = m['root']?.toString();
    final isAlias = root != null && root != id;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: ListTile(
        leading: const Icon(Icons.smart_toy_outlined),
        title: Text(id),
        subtitle: isAlias ? Text('路由 → $root') : null,
        trailing: isAlias
            ? Chip(
                label: const Text('别名'),
                visualDensity: VisualDensity.compact,
                backgroundColor: theme.colorScheme.tertiaryContainer,
              )
            : Chip(
                label: const Text('主模型'),
                visualDensity: VisualDensity.compact,
                backgroundColor: theme.colorScheme.primaryContainer,
              ),
      ),
    );
  }

  Widget _buildToolsetTile(Map<dynamic, dynamic> t, ThemeData theme) {
    final enabled = t['enabled'] == true;
    final tools = t['tools'];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: ListTile(
        leading: Icon(
          enabled ? Icons.handyman_outlined : Icons.handyman,
          color: enabled ? theme.colorScheme.primary : theme.hintColor,
        ),
        title: Text(t['label']?.toString() ?? t['name']?.toString() ?? '?'),
        subtitle: Text(
          '${t['description'] ?? ''}'
          '${tools is List ? '（${tools.length} 个工具）' : ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Icon(
          enabled ? Icons.check_circle_outline : Icons.remove_circle_outline,
          size: 18,
          color: enabled ? Colors.green : theme.hintColor,
        ),
      ),
    );
  }

  Widget _buildCapabilities(ThemeData theme) {
    final features = _capabilities?['features'];
    if (features is! Map) return const SizedBox.shrink();
    final entries = features.entries
        .where((e) => e.value is bool)
        .toList(growable: false);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final e in entries)
              Chip(
                avatar: Icon(
                  e.value == true ? Icons.check : Icons.close,
                  size: 14,
                  color: e.value == true ? Colors.green : theme.hintColor,
                ),
                label: Text(e.key.toString(),
                    style: theme.textTheme.labelSmall),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }
}
