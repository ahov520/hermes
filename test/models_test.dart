import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/api.dart';
import 'package:hermes_mobile/models.dart';

void main() {
  group('flattenContent', () {
    test('字符串原样返回', () {
      expect(flattenContent('hello'), 'hello');
    });

    test('parts 数组拍平为文本', () {
      expect(
        flattenContent(<Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': '第一段'},
          <String, dynamic>{'type': 'output_text', 'text': '第二段'},
        ]),
        '第一段\n第二段',
      );
    });

    test('图片 part 显示占位符', () {
      expect(
        flattenContent(<Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'image_url',
            'image_url': <String, dynamic>{'url': 'data:image/png;base64,x'}
          },
        ]),
        '[图片]',
      );
    });

    test('null 返回空串', () {
      expect(flattenContent(null), '');
    });
  });

  group('模型解析', () {
    test('HermesSession.fromJson', () {
      final s = HermesSession.fromJson(<String, dynamic>{
        'id': 'api_1',
        'title': '测试会话',
        'message_count': 5,
        'started_at': 1784434940.0,
      });
      expect(s.id, 'api_1');
      expect(s.displayTitle, '测试会话');
      expect(s.messageCount, 5);
    });

    test('HermesSession 无标题时回退到 preview/id', () {
      expect(
        HermesSession.fromJson(<String, dynamic>{
          'id': 'api_2',
          'preview': '你好',
        }).displayTitle,
        '你好',
      );
      expect(
        HermesSession.fromJson(<String, dynamic>{'id': 'api_3'}).displayTitle,
        'api_3',
      );
    });

    test('CronJob.fromJson 与 paused 语义', () {
      final job = CronJob.fromJson(<String, dynamic>{
        'id': 'a1b2c3d4e5f6',
        'name': '日报',
        'schedule': <String, dynamic>{'kind': 'cron', 'expr': '0 9 * * *'},
        'schedule_display': '0 9 * * *',
        'enabled': true,
        'state': 'paused',
      });
      expect(job.scheduleDisplay, '0 9 * * *');
      expect(job.paused, isTrue);
    });

    test('ChatMessage.fromJson 处理 tool 角色', () {
      final m = ChatMessage.fromJson(<String, dynamic>{
        'role': 'tool',
        'tool_name': 'terminal',
        'content': 'total 12',
      });
      expect(m.role, 'tool');
      expect(m.toolName, 'terminal');
      expect(m.content, 'total 12');
    });
  });

  group('decodeSse', () {
    Future<List<SseEvent>> collect(String wire) => decodeSse(
          Stream<List<int>>.fromIterable(<List<int>>[utf8.encode(wire)]),
        ).toList();

    test('解析命名事件与数据', () async {
      final events = await collect(
        'event: assistant.delta\ndata: {"delta":"你"}\n\n'
        'event: assistant.delta\ndata: {"delta":"好"}\n\n',
      );
      expect(events, hasLength(2));
      expect(events[0].event, 'assistant.delta');
      expect(events[0].json['delta'], '你');
      expect(events[1].json['delta'], '好');
    });

    test('忽略 keepalive 注释行', () async {
      final events = await collect(
        ': keepalive\n\ndata: {"event":"message.delta","delta":"x"}\n\n'
        ': stream closed\n\n',
      );
      expect(events, hasLength(1));
      expect(events.single.json['event'], 'message.delta');
    });

    test('多行 data 合并，缺省事件名为 message', () async {
      final events = await collect('data: 第一\ndata: 第二\n\n');
      expect(events.single.event, 'message');
      expect(events.single.data, '第一\n第二');
    });

    test('跨 chunk 分片也能正确拼帧', () async {
      const wire = 'event: done\ndata: {}\n\n';
      final chunks = <List<int>>[];
      for (var i = 0; i < wire.length; i += 3) {
        chunks.add(utf8.encode(
            wire.substring(i, i + 3 > wire.length ? wire.length : i + 3)));
      }
      final events = await decodeSse(Stream.fromIterable(chunks)).toList();
      expect(events.single.event, 'done');
    });

    test('流末尾无空行也能透出最后一帧', () async {
      final events = await collect('data: [DONE]');
      expect(events.single.data, '[DONE]');
    });
  });
}
