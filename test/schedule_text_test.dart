import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/schedule_text.dart';

void main() {
  group('describeSchedule', () {
    test('间隔表达式', () {
      expect(describeSchedule('every 30m'), '每 30 分钟');
      expect(describeSchedule('every 2h'), '每 2 小时');
      expect(describeSchedule('every 1d'), '每 1 天');
    });

    test('一次性相对时长', () {
      expect(describeSchedule('30m'), '一次性（30 分钟后）');
      expect(describeSchedule('2h'), '一次性（2 小时后）');
    });

    test('ISO 一次性时间', () {
      expect(describeSchedule('2026-02-03T14:00'), '一次性定时');
    });

    test('cron 常见模式', () {
      expect(describeSchedule('* * * * *'), '每分钟');
      expect(describeSchedule('*/5 * * * *'), '每 5 分钟');
      expect(describeSchedule('30 * * * *'), '每小时第 30 分');
      expect(describeSchedule('0 */2 * * *'), '每 2 小时');
      expect(describeSchedule('0 9 * * *'), '每天 09:00');
      expect(describeSchedule('0 9 * * 1-5'), '工作日 09:00');
      expect(describeSchedule('30 8 * * 1'), '每周一 08:30');
      expect(describeSchedule('0 9 * * 0'), '每周日 09:00');
      expect(describeSchedule('0 0 1 * *'), '每月 1 日 00:00');
    });

    test('无法识别时原样返回', () {
      expect(describeSchedule('0 9 1 1 *'), '0 9 1 1 *');
      expect(describeSchedule(null), '-');
      expect(describeSchedule(''), '-');
    });
  });

  group('relativeCountdown', () {
    final now = DateTime(2026, 7, 19, 12, 0);

    test('分钟级', () {
      expect(
        relativeCountdown(
            DateTime(2026, 7, 19, 12, 25).toIso8601String(),
            now: now),
        '25 分钟后',
      );
    });

    test('小时级', () {
      expect(
        relativeCountdown(
            DateTime(2026, 7, 19, 15, 0).toIso8601String(),
            now: now),
        '3 小时后',
      );
      expect(
        relativeCountdown(
            DateTime(2026, 7, 19, 15, 30).toIso8601String(),
            now: now),
        '3 小时 30 分后',
      );
    });

    test('天级与边界', () {
      expect(
        relativeCountdown(
            DateTime(2026, 7, 21, 15, 0).toIso8601String(),
            now: now),
        '2 天后',
      );
      expect(
        relativeCountdown(
            DateTime(2026, 7, 19, 12, 0, 30).toIso8601String(),
            now: now),
        '即将',
      );
      expect(
        relativeCountdown(
            DateTime(2026, 7, 19, 11, 0).toIso8601String(),
            now: now),
        '已过期',
      );
    });

    test('空与非法输入', () {
      expect(relativeCountdown(null, now: now), '-');
      expect(relativeCountdown('not-a-date', now: now), '-');
    });
  });
}
