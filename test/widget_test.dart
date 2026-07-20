import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('应用能启动并显示五个底部导航', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const HermesApp());
    await tester.pumpAndSettle();
    expect(find.text('聊天'), findsAtLeastNWidgets(1));
    expect(find.text('终端'), findsAtLeastNWidgets(1));
    expect(find.text('任务'), findsAtLeastNWidgets(1));
    expect(find.text('定时'), findsAtLeastNWidgets(1));
    expect(find.text('更多'), findsAtLeastNWidgets(1));
    // 未配置 API Key 时提示先配置（Flutter 3.44 起 IndexedStack 非活动子树
    // 是 Offstage，需 skipOffstage: false 才能命中）
    expect(
      find.textContaining('请先在「设置」页配置', skipOffstage: false),
      findsWidgets,
    );
  });
}
