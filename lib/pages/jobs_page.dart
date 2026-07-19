import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../schedule_text.dart';
import '../state.dart';

/// 定时任务页：cron 任务的查看、新建、编辑、暂停/恢复、立即运行、删除。
class JobsPage extends StatefulWidget {
  const JobsPage({super.key, required this.state});

  final AppState state;

  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  List<CronJob> _jobs = <CronJob>[];
  bool _loading = false;
  Timer? _countdownTimer;

  HermesApi? get _api => widget.state.api;

  @override
  void initState() {
    super.initState();
    _load();
    // 倒计时文案每分钟刷新一次
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null || _loading) return;
    setState(() => _loading = true);
    try {
      final list = await api.listJobs();
      if (!mounted) return;
      setState(() {
        _jobs = list
            .whereType<Map<String, dynamic>>()
            .map(CronJob.fromJson)
            .toList();
      });
    } catch (e) {
      _toast('加载任务失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _action(CronJob job, String action, String label) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.jobAction(job.id, action);
      _toast('$label 成功');
      await _load();
    } catch (e) {
      _toast('$label 失败: $e');
    }
  }

  Future<void> _delete(CronJob job) async {
    final api = _api;
    if (api == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除定时任务'),
        content: Text('确定删除「${job.name}」吗？'),
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
      await api.deleteJob(job.id);
      await _load();
    } catch (e) {
      _toast('删除失败: $e');
    }
  }

  Future<void> _editDialog({CronJob? existing}) async {
    final api = _api;
    if (api == null) return;
    final name = TextEditingController(text: existing?.name ?? '');
    final schedule = TextEditingController(
        text: existing?.scheduleDisplay ?? 'every 30m');
    final prompt = TextEditingController(text: existing?.prompt ?? '');
    final repeat = TextEditingController(
        text: existing?.repeatTimes?.toString() ?? '');
    final selectedSkills = <String>{...?existing?.skills};
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? '新建定时任务' : '编辑定时任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: schedule,
                  decoration: const InputDecoration(
                    labelText: '调度',
                    hintText: 'every 30m / 0 9 * * * / 2026-02-03T14:00 / 2h',
                    helperText: '间隔：every 30m；cron：0 9 * * *；一次性：2h 或 ISO 时间',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: prompt,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '提示词',
                    hintText: '触发时交给 Hermes 执行的指令',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: repeat,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '重复次数（可选）',
                    hintText: '留空表示不限次数',
                  ),
                ),
                const SizedBox(height: 12),
                Text('附加技能（可选）',
                    style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 4),
                FutureBuilder<List<dynamic>>(
                  future: api.skills(),
                  builder: (context, snapshot) {
                    final skills = snapshot.data ?? <dynamic>[];
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(8),
                        child: LinearProgressIndicator(),
                      );
                    }
                    if (skills.isEmpty) return const Text('无可用技能');
                    return Wrap(
                      spacing: 6,
                      runSpacing: -4,
                      children: [
                        for (final s in skills)
                          if (s is Map<String, dynamic>)
                            FilterChip(
                              label: Text(s['name']?.toString() ?? '?'),
                              selected:
                                  selectedSkills.contains(s['name']?.toString()),
                              onSelected: (selected) {
                                setDialogState(() {
                                  final skillName = s['name']?.toString();
                                  if (skillName == null) return;
                                  if (selected) {
                                    selectedSkills.add(skillName);
                                  } else {
                                    selectedSkills.remove(skillName);
                                  }
                                });
                              },
                            ),
                      ],
                    );
                  },
                ),
              ],
            ),
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
      ),
    );
    if (saved != true) return;
    final repeatValue = int.tryParse(repeat.text.trim());
    try {
      if (existing == null) {
        await api.createJob(
          name: name.text.trim(),
          schedule: schedule.text.trim(),
          prompt: prompt.text.trim(),
          skills: selectedSkills.isEmpty ? null : selectedSkills.toList(),
          repeat: repeatValue,
        );
        _toast('已创建');
      } else {
        await api.updateJob(existing.id, <String, dynamic>{
          'name': name.text.trim(),
          'schedule': schedule.text.trim(),
          'prompt': prompt.text.trim(),
          if (selectedSkills.isNotEmpty) 'skills': selectedSkills.toList(),
          if (repeatValue != null && repeatValue > 0) 'repeat': repeatValue,
        });
        _toast('已保存');
      }
      await _load();
    } catch (e) {
      _toast('保存失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    return Scaffold(
      appBar: AppBar(
        title: const Text('定时任务'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: api == null
          ? null
          : FloatingActionButton(
              onPressed: () => _editDialog(),
              child: const Icon(Icons.add),
            ),
      body: api == null
          ? const Center(child: Text('请先在「设置」页配置服务器地址和 API Key'))
          : _loading && _jobs.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _jobs.isEmpty
                  ? Center(
                      child: Text('暂无定时任务，点右下角新建',
                          style:
                              TextStyle(color: Theme.of(context).hintColor)),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        itemCount: _jobs.length,
                        itemBuilder: (context, i) => _buildJob(_jobs[i]),
                      ),
                    ),
    );
  }

  Widget _buildJob(CronJob job) {
    final theme = Theme.of(context);
    final paused = job.paused;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(job.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                Chip(
                  label: Text(paused ? '已暂停' : '运行中'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: paused
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.primaryContainer,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('调度: ${describeSchedule(job.scheduleDisplay)}',
                style: theme.textTheme.bodySmall),
            Text(
              '下次运行: ${formatIso(job.nextRunAt)}'
              '${job.nextRunAt != null ? '（${relativeCountdown(job.nextRunAt)}）' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            if (job.skills != null && job.skills!.isNotEmpty)
              Text('技能: ${job.skills!.join('、')}',
                  style: theme.textTheme.bodySmall),
            if (job.repeatTimes != null)
              Text('重复: ${job.repeatCompleted ?? 0}/${job.repeatTimes} 次',
                  style: theme.textTheme.bodySmall),
            if (job.lastRunAt != null)
              Text(
                '上次: ${formatIso(job.lastRunAt)}'
                '${job.lastStatus != null ? ' · ${job.lastStatus}' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            if (job.lastError != null && job.lastError!.isNotEmpty)
              Text('错误: ${job.lastError}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            if (job.prompt != null && job.prompt!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(job.prompt!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: '立即运行',
                  onPressed: () => _action(job, 'run', '触发'),
                ),
                IconButton(
                  icon: Icon(paused ? Icons.play_circle : Icons.pause_circle),
                  tooltip: paused ? '恢复' : '暂停',
                  onPressed: () =>
                      _action(job, paused ? 'resume' : 'pause', paused ? '恢复' : '暂停'),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: '编辑',
                  onPressed: () => _editDialog(existing: job),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '删除',
                  onPressed: () => _delete(job),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
