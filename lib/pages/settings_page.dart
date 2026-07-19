import 'package:flutter/material.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';

/// 设置页：连接配置（服务器地址 + API Key）、连通性测试、外观设置、
/// 服务器状态 / 模型 / 技能 / 工具集浏览、关于信息。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url =
      TextEditingController(text: widget.state.baseUrl);
  late final TextEditingController _key =
      TextEditingController(text: widget.state.apiKey);
  bool _obscure = true;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  Future<_ServerInfo>? _infoFuture;
  _ServerInfo? _serverInfo; // 最近一次加载成功的服务器信息（关于区显示版本用）

  HermesApi? get _api => widget.state.api;

  /// 服务器版本（未加载成功时显示 -）。
  String get _serverVersion =>
      _serverInfo?.health?['version']?.toString() ?? '-';

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.state.save(baseUrl: _url.text, apiKey: _key.text);
    if (!mounted) return;
    setState(() {
      _testResult = null;
      _infoFuture = null;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已保存')));
  }

  void _syncControllers() {
    _url.text = widget.state.baseUrl;
    _key.text = widget.state.apiKey;
  }

  Future<void> _addProfileDialog() async {
    final name = TextEditingController();
    final url = TextEditingController(text: _url.text);
    final key = TextEditingController(text: _key.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建连接配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: '配置名称',
                hintText: '如：家里 Wi-Fi / 隧道远程',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: url,
              decoration: const InputDecoration(labelText: '服务器地址'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: key,
              decoration: const InputDecoration(labelText: 'API Key'),
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
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.state.addProfile(
      name: name.text,
      baseUrl: url.text,
      apiKey: key.text,
    );
    if (!mounted) return;
    setState(() {
      _syncControllers();
      _testResult = null;
      _infoFuture = null;
    });
  }

  Future<void> _deleteActiveProfile() async {
    final state = widget.state;
    if (state.profiles.length <= 1) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('至少保留一套配置')));
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除「${state.activeProfile.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await state.deleteProfile(state.activeIndex);
    if (!mounted) return;
    setState(() {
      _syncControllers();
      _testResult = null;
      _infoFuture = null;
    });
  }

  Future<void> _test() async {
    await _save();
    final api = _api;
    if (api == null) {
      setState(() {
        _testOk = false;
        _testResult = '请填写 API Key';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final caps = await api.capabilities();
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = true;
        _testResult =
            '连接成功 · ${caps['platform'] ?? 'hermes'} · 模型 ${caps['model'] ?? '-'}';
        _infoFuture = _refreshInfo(api);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testResult = '连接失败: $e';
      });
    }
  }

  Future<_ServerInfo> _loadInfo(HermesApi api) async {
    final info = _ServerInfo();
    try {
      info.health = await api.healthDetailed();
    } catch (_) {
      info.health = await api.health();
    }
    try {
      info.models = await api.models();
    } catch (_) {}
    try {
      info.skills = await api.skills();
    } catch (_) {}
    try {
      info.toolsets = await api.toolsets();
    } catch (_) {}
    return info;
  }

  /// 加载服务器信息并缓存结果，供「关于」区显示服务器版本。
  Future<_ServerInfo> _refreshInfo(HermesApi api) async {
    final info = await _loadInfo(api);
    if (mounted) setState(() => _serverInfo = info);
    return info;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('连接', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButton<int>(
                  value: widget.state.activeIndex,
                  isExpanded: true,
                  items: [
                    for (var i = 0; i < widget.state.profiles.length; i++)
                      DropdownMenuItem<int>(
                        value: i,
                        child: Text(
                          widget.state.profiles[i].name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (i) async {
                    if (i == null) return;
                    await widget.state.selectProfile(i);
                    if (!mounted) return;
                    setState(() {
                      _syncControllers();
                      _testResult = null;
                      _infoFuture = null;
                    });
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: '新建配置',
                onPressed: _addProfileDialog,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除当前配置',
                onPressed: _deleteActiveProfile,
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'http://192.168.2.159:8642',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: '服务端 API_SERVER_KEY',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                icon:
                    Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('测试连接'),
                ),
              ),
            ],
          ),
          if (_testResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                color: _testOk
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_testResult!),
                ),
              ),
            ),
          const SizedBox(height: 24),
          Text('外观', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment<ThemeMode>(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto),
                label: Text('跟随系统'),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode),
                label: Text('浅色'),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode),
                label: Text('深色'),
              ),
            ],
            selected: <ThemeMode>{widget.state.themeMode},
            onSelectionChanged: (modes) =>
                widget.state.setThemeMode(modes.first),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in hermesSeedColors)
                _seedColorDot(theme, color),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('服务器信息', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (_api != null)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () =>
                      setState(() => _infoFuture = _refreshInfo(_api!)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_api == null)
            Text('配置并保存连接后可查看服务器信息',
                style: TextStyle(color: theme.hintColor))
          else
            FutureBuilder<_ServerInfo>(
              future: _infoFuture ??= _refreshInfo(_api!),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError || snapshot.data == null) {
                  return Text('加载失败: ${snapshot.error ?? '未知错误'}');
                }
                return _buildInfo(snapshot.data!);
              },
            ),
          const SizedBox(height: 24),
          Text('关于', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.smart_toy_outlined),
                  title: Text('Hermes Mobile'),
                  subtitle: Text('版本 0.1.0'),
                ),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('服务器版本'),
                  subtitle: Text(_serverVersion),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 主题色选择圆点：选中的加粗边框并显示对勾。
  Widget _seedColorDot(ThemeData theme, Color color) {
    final selected = widget.state.seedColor.value == color.value;
    return GestureDetector(
      onTap: () => widget.state.setSeedColor(color),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: theme.colorScheme.outline, width: 3)
              : null,
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 20)
            : null,
      ),
    );
  }

  Widget _buildInfo(_ServerInfo info) {
    final health = info.health ?? <String, dynamic>{};
    final platforms = health['platforms'];
    return Column(
      children: [
        _infoTile(
          icon: Icons.monitor_heart_outlined,
          title: '状态',
          children: [
            _kv('版本', health['version']?.toString() ?? '-'),
            _kv('网关', health['gateway_state']?.toString() ?? '-'),
            _kv('活跃代理', health['active_agents']?.toString() ?? '-'),
            if (platforms is Map)
              for (final entry in platforms.entries)
                _kv(
                  '平台 ${entry.key}',
                  entry.value is Map
                      ? (entry.value['state']?.toString() ?? '-')
                      : entry.value.toString(),
                ),
          ],
        ),
        _infoTile(
          icon: Icons.model_training,
          title: '模型 (${info.models.length})',
          children: [
            for (final m in info.models)
              _kv(
                m is Map ? (m['id']?.toString() ?? '?') : m.toString(),
                m is Map && m['root'] != m['id']
                    ? '→ ${m['root']}'
                    : '',
              ),
          ],
        ),
        _infoTile(
          icon: Icons.auto_awesome_outlined,
          title: '技能 (${info.skills.length})',
          children: [
            for (final s in info.skills)
              _kv(
                s is Map ? (s['name']?.toString() ?? '?') : s.toString(),
                s is Map ? (s['description']?.toString() ?? '') : '',
              ),
          ],
        ),
        _infoTile(
          icon: Icons.handyman_outlined,
          title: '工具集 (${info.toolsets.length})',
          children: [
            for (final t in info.toolsets)
              _kv(
                t is Map ? (t['name']?.toString() ?? '?') : t.toString(),
                t is Map
                    ? '${t['enabled'] == true ? '启用' : '停用'}'
                        '${t['tools'] is List ? ' · ${(t['tools'] as List).length} 个工具' : ''}'
                    : '',
              ),
          ],
        ),
      ],
    );
  }

  Widget _infoTile({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        childrenPadding:
            const EdgeInsets.only(left: 16, right: 16, bottom: 12),
        children: children,
      ),
    );
  }

  Widget _kv(String key, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(key,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 3,
            child: Text(value,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor)),
          ),
        ],
      ),
    );
  }
}

class _ServerInfo {
  Map<String, dynamic>? health;
  List<dynamic> models = <dynamic>[];
  List<dynamic> skills = <dynamic>[];
  List<dynamic> toolsets = <dynamic>[];
}
