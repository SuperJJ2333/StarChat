import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/app_connection_status.dart';
import 'package:liuhetong_mobile/ui/components/wechat_scaffold.dart';

void main() {
  testWidgets('scaffold capsule hides while connecting and shows offline',
      (tester) async {
    final hub = AppConnectionStatusHub.shared;
    final owner = Object();
    final source = ValueNotifier<AppConnectionStatus>(
        AppConnectionStatus.connecting);
    addTearDown(() => hub.unbind(owner));
    hub.bind<AppConnectionStatus>(owner, source, (status) => status);

    await tester.pumpWidget(const CupertinoApp(
      home: WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(middle: Text('消息')),
        child: SizedBox.expand(),
      ),
    ));
    await tester.pump();

    // connecting 态不再在导航栏下显示"正在连接…"加载胶囊。
    expect(find.text('正在连接…'), findsNothing);
    expect(find.byKey(const Key('network-status-capsule')), findsNothing);

    // 真正离线时胶囊出现且可读。
    source.value = AppConnectionStatus.offline;
    await tester.pump();
    expect(find.text('网络不可用，联网后自动重试'), findsOneWidget);
    expect(find.byKey(const Key('network-status-capsule')), findsOneWidget);

    // 恢复连接后胶囊消失。
    source.value = AppConnectionStatus.connected;
    await tester.pump();
    expect(find.byKey(const Key('network-status-capsule')), findsNothing);
  });
}
