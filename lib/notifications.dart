import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知服务：任务等待审批 / 完成 / 失败时推送系统通知。
///
/// 仅使用即时通知（show）。依赖 flutter_local_notifications 17+，
/// Android 侧需在 app Gradle 启用 core library desugaring（见 CI build.yml）。
/// 测试环境下插件不可用时会静默降级。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const int _channelNotificationBaseId = 4200;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;

  /// App 是否处于前台（由 main.dart 的生命周期观察者维护）。前台时不打扰。
  static bool appInForeground = true;

  Future<void> init() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(settings);
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'hermes_runs',
          '任务通知',
          description: 'Hermes 任务的审批请求与完成提醒',
          importance: Importance.high,
        ),
      );
      _ready = true;
    } catch (e) {
      // 测试环境或不支持的平台上静默降级
      debugPrint('通知初始化失败（忽略）: $e');
      _ready = false;
    }
  }

  Future<void> _notify(String title, String body) async {
    if (!_ready) return;
    // 前台可见时不推系统通知，页面内已有展示
    if (appInForeground) return;
    try {
      await _plugin.show(
        _channelNotificationBaseId +
            DateTime.now().millisecondsSinceEpoch % 1000,
        title,
        body.length > 120 ? '${body.substring(0, 120)}…' : body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'hermes_runs',
            '任务通知',
            channelDescription: 'Hermes 任务的审批请求与完成提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('通知发送失败（忽略）: $e');
    }
  }

  Future<void> runNeedsApproval(String runId, String command) =>
      _notify('Hermes 任务等待审批', command.isEmpty ? '有一个工具调用需要确认' : command);

  Future<void> runCompleted(String runId, String input) =>
      _notify('Hermes 任务完成', input);

  Future<void> runFailed(String runId, String error) =>
      _notify('Hermes 任务失败', error.isEmpty ? '未知错误' : error);
}
