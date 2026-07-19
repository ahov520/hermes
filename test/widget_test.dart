import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('应用能启动并显示四个底部导航', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const HermesApp());
    await tester.pumpAndSettle();
    expect(find.text('聊天'), findsAtLeastNWidgets(1));
    expect(find.text('终端'), findsAtLeastNWidgets(1));
    expect(find.text('任务'), findsAtLeastNWidgets(1));
    expect(find.text('定时'), findsAtLeastNWidgets(1));
    expect(find.text('设置'), findsAtLeastNWidgets(1));
    // 未配置 API Key 时提示先配置
    expect(find.textContaining('请先在「设置」页配置'), findsWidgets);
  });
}
