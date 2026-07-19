/// Hermes API 数据模型。

/// 将 API 返回的 message content（字符串或 parts 数组）拍平为纯文本。
String flattenContent(dynamic content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    final parts = <String>[];
    for (final part in content) {
      if (part is Map) {
        final text = part['text'] ?? part['content'];
        if (text != null) {
          parts.add(text.toString());
        } else if (part['type'] == 'image_url' || part['type'] == 'input_image') {
          parts.add('[图片]');
        }
      } else if (part != null) {
        parts.add(part.toString());
      }
    }
    return parts.join('\n');
  }
  return content.toString();
}

/// Unix 秒（double/int）格式化为本地时间字符串。
String formatUnixTs(num? ts) {
  if (ts == null || ts == 0) return '-';
  final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round()).toLocal();
  return _fmtDt(dt);
}

String formatIso(String? iso) {
  if (iso == null || iso.isEmpty) return '-';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  return _fmtDt(dt.toLocal());
}

String _fmtDt(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

class HermesSession {
  HermesSession({
    required this.id,
    this.title,
    this.model,
    this.source,
    this.startedAt,
    this.lastActive,
    this.messageCount = 0,
    this.preview,
    this.endReason,
    this.parentSessionId,
  });

  factory HermesSession.fromJson(Map<String, dynamic> json) {
    return HermesSession(
      id: (json['id'] ?? '').toString(),
      title: json['title']?.toString(),
      model: json['model']?.toString(),
      source: json['source']?.toString(),
      startedAt: (json['started_at'] as num?)?.toDouble(),
      lastActive: (json['last_active'] as num?)?.toDouble(),
      messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
      preview: json['preview']?.toString(),
      endReason: json['end_reason']?.toString(),
      parentSessionId: json['parent_session_id']?.toString(),
    );
  }

  final String id;
  final String? title;
  final String? model;
  final String? source;
  final double? startedAt;
  final double? lastActive;
  final int messageCount;
  final String? preview;
  final String? endReason;
  final String? parentSessionId;

  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    if (preview != null && preview!.isNotEmpty) return preview!;
    return id;
  }
}

class ChatMessage {
  ChatMessage({
    this.id,
    required this.role,
    required this.content,
    this.toolName,
    this.toolCallId,
    this.timestamp,
    this.tokenCount,
    this.reasoning,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: (json['id'] as num?)?.toInt(),
      role: (json['role'] ?? 'assistant').toString(),
      content: flattenContent(json['content']),
      toolName: json['tool_name']?.toString(),
      toolCallId: json['tool_call_id']?.toString(),
      timestamp: (json['timestamp'] as num?)?.toDouble(),
      tokenCount: (json['token_count'] as num?)?.toInt(),
      reasoning: json['reasoning_content']?.toString() ??
          json['reasoning']?.toString(),
    );
  }

  final int? id;
  final String role;
  final String content;
  final String? toolName;
  final String? toolCallId;
  final double? timestamp;
  final int? tokenCount;
  final String? reasoning;
}

class CronJob {
  CronJob({
    required this.id,
    required this.name,
    this.prompt,
    this.scheduleDisplay,
    this.enabled = true,
    this.state,
    this.nextRunAt,
    this.lastRunAt,
    this.lastStatus,
    this.lastError,
    this.deliver,
    this.skills,
    this.repeatTimes,
    this.repeatCompleted,
    this.latestExecution,
  });

  factory CronJob.fromJson(Map<String, dynamic> json) {
    final schedule = json['schedule'];
    final repeat = json['repeat'];
    final latestExecution = json['latest_execution'];
    return CronJob(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      prompt: json['prompt']?.toString(),
      scheduleDisplay: json['schedule_display']?.toString() ??
          (schedule is Map ? schedule['display']?.toString() : null),
      enabled: json['enabled'] != false,
      state: json['state']?.toString(),
      nextRunAt: json['next_run_at']?.toString(),
      lastRunAt: json['last_run_at']?.toString(),
      lastStatus: json['last_status']?.toString(),
      lastError: json['last_error']?.toString(),
      deliver: json['deliver']?.toString(),
      skills: (json['skills'] as List?)
          ?.map((e) => e.toString())
          .toList(growable: false),
      repeatTimes:
          repeat is Map ? (repeat['times'] as num?)?.toInt() : null,
      repeatCompleted:
          repeat is Map ? (repeat['completed'] as num?)?.toInt() : null,
      latestExecution: latestExecution is Map
          ? Map<String, dynamic>.from(latestExecution)
          : null,
    );
  }

  final String id;
  final String name;
  final String? prompt;
  final String? scheduleDisplay;
  final bool enabled;
  final String? state;
  final String? nextRunAt;
  final String? lastRunAt;
  final String? lastStatus;
  final String? lastError;
  final String? deliver;
  final List<String>? skills;
  final int? repeatTimes;
  final int? repeatCompleted;

  /// 最近一次执行记录（latest_execution 原始 JSON，未解析）。
  final Map<String, dynamic>? latestExecution;

  bool get paused => state == 'paused' || !enabled;

  /// 最近一次执行的一行中文摘要；无记录或无任何可用字段时为 null。
  String? get latestExecutionSummary {
    final exec = latestExecution;
    if (exec == null) return null;
    final parts = <String>[];
    final status = exec['status']?.toString();
    if (status != null && status.isNotEmpty) {
      parts.add(switch (status) {
        'completed' => '成功',
        'failed' => '失败',
        'cancelled' => '已取消',
        'running' => '运行中',
        _ => status,
      });
    }
    final startedAt = exec['started_at']?.toString();
    if (startedAt != null && startedAt.isNotEmpty) {
      parts.add('开始于 ${formatIso(startedAt)}');
    }
    final finishedAt = exec['finished_at']?.toString();
    if (finishedAt != null && finishedAt.isNotEmpty) {
      parts.add('结束于 ${formatIso(finishedAt)}');
    }
    final error = exec['error']?.toString();
    if (error != null && error.isNotEmpty) {
      parts.add('错误: $error');
    }
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }
}

class RunRecord {
  RunRecord({
    required this.runId,
    required this.input,
    required this.createdAt,
    this.status = 'queued',
  });

  final String runId;
  final String input;
  final DateTime createdAt;
  String status;

  bool get isActive => const <String>{
        'queued',
        'running',
        'waiting_for_approval',
        'stopping',
      }.contains(status);
}
