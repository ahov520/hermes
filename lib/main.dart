import 'package:flutter/material.dart';

import 'models.dart';
import 'notifications.dart';
import 'pages/chat_page.dart';
import 'pages/jobs_page.dart';
import 'pages/runs_page.dart';
import 'pages/settings_page.dart';
import 'pages/terminal_page.dart';
import 'state.dart';
import 'theme.dart';

void main() {
  runApp(const HermesApp());
}

class HermesApp extends StatefulWidget {
  const HermesApp({super.key});

  @override
  State<HermesApp> createState() => _HermesAppState();
}

class _HermesAppState extends State<HermesApp> with WidgetsBindingObserver {
  final AppState state = AppState();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.load();
    NotificationService.instance.init();
    // 点击通知（审批/完成/失败）直达对应任务详情页
    NotificationService.onRunNotificationTap = _openRunFromNotification;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.onRunNotificationTap = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    NotificationService.appInForeground =
        lifecycleState == AppLifecycleState.resumed;
  }

  void _openRunFromNotification(String runId) {
    final api = state.api;
    if (api == null) return;
    _navigatorKey.currentState?.push(MaterialPageRoute<void>(
      builder: (_) => RunDetailPage(
        api: api,
        record: RunRecord(
          runId: runId,
          input: '来自通知的任务',
          createdAt: DateTime.now(),
          status: 'running',
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => MaterialApp(
        title: 'Hermes',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigatorKey,
        themeMode: state.themeMode,
        theme: buildHermesTheme(state.seedColor, Brightness.light),
        darkTheme: buildHermesTheme(state.seedColor, Brightness.dark),
        home: HomeShell(state: state),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final pages = <Widget>[
      ChatPage(state: state),
      TerminalPage(state: state),
      RunsPage(state: state),
      JobsPage(state: state),
      SettingsPage(state: state),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: '聊天'),
          NavigationDestination(icon: Icon(Icons.terminal), label: '终端'),
          NavigationDestination(icon: Icon(Icons.rocket_launch_outlined), label: '任务'),
          NavigationDestination(icon: Icon(Icons.schedule_outlined), label: '定时'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
        ],
      ),
    );
  }
}
