import 'package:flutter/material.dart';

import '../state.dart';
import 'models_page.dart';
import 'settings_page.dart';
import 'skills_page.dart';
import 'usage_page.dart';

/// 「更多」页：仿 Hermes Studio 分组侧栏的功能目录。
class MorePage extends StatelessWidget {
  const MorePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = <_Group>[
      _Group('助手', [
        _Entry(Icons.auto_awesome_outlined, '技能', '浏览 agent 技能库',
            (c) => SkillsPage(state: state)),
        _Entry(Icons.model_training, '模型', '可用模型与工具集、能力清单',
            (c) => ModelsPage(state: state)),
      ]),
      _Group('监控', [
        _Entry(Icons.insights_outlined, '用量', 'token 与费用统计（按会话聚合）',
            (c) => UsagePage(state: state)),
      ]),
      _Group('系统', [
        _Entry(Icons.settings_outlined, '设置', '连接、外观、服务器信息',
            (c) => SettingsPage(state: state)),
      ]),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('更多')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final group in groups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(group.title, style: theme.textTheme.labelMedium),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < group.entries.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 56),
                    _buildTile(context, group.entries[i]),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context, _Entry entry) {
    return ListTile(
      leading: Icon(entry.icon),
      title: Text(entry.title),
      subtitle: Text(entry.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: entry.builder),
      ),
    );
  }
}

class _Group {
  const _Group(this.title, this.entries);

  final String title;
  final List<_Entry> entries;
}

class _Entry {
  const _Entry(this.icon, this.title, this.subtitle, this.builder);

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;
}
