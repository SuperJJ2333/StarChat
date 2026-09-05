import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/update/app_update.dart';
import 'package:liuhetong_mobile/features/update/app_update_dialog.dart';

const _info = AppUpdateInfo(
  latestVersion: '0.4.0',
  latestBuild: 4,
  minSupportedBuild: 2,
  notes: '修复已知问题，新增版本更新提醒。',
  apkUrl: 'https://www.liuhetong888.com/downloads/app-release.apk',
);

Future<void> _openDialog(
  WidgetTester tester, {
  required int currentBuild,
  required ValueChanged<String> onLaunch,
  VoidCallback? onDeferred,
}) async {
  late final BuildContext context;
  await tester.pumpWidget(CupertinoApp(
    home: Builder(
      builder: (builderContext) {
        context = builderContext;
        return const CupertinoPageScaffold(child: Text('首页'));
      },
    ),
  ));
  showAppUpdateDialog(
    context,
    info: _info,
    currentBuild: currentBuild,
    launchExternal: (url) async => onLaunch(url),
    onDeferred: onDeferred,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dismissible update offers 更新 and 稍后再说', (tester) async {
    final launched = <String>[];
    var deferred = 0;
    await _openDialog(
      tester,
      currentBuild: 3,
      onLaunch: launched.add,
      onDeferred: () => deferred++,
    );

    expect(find.text('发现新版本 0.4.0'), findsOneWidget);
    expect(find.text('修复已知问题，新增版本更新提醒。'), findsOneWidget);
    expect(find.byKey(const Key('app-update-defer')), findsOneWidget);
    expect(find.byKey(const Key('app-update-now')), findsOneWidget);
    expect(find.byKey(const Key('app-update-forced-dialog')), findsNothing);

    await tester.tap(find.byKey(const Key('app-update-now')));
    await tester.pump();
    expect(launched.single, _info.apkUrl);
  });

  testWidgets('稍后再说 closes the dialog and notifies the caller', (tester) async {
    var deferred = 0;
    await _openDialog(
      tester,
      currentBuild: 3,
      onLaunch: (_) {},
      onDeferred: () => deferred++,
    );

    await tester.tap(find.byKey(const Key('app-update-defer')));
    await tester.pumpAndSettle();

    expect(deferred, 1);
    expect(find.byKey(const Key('app-update-dialog')), findsNothing);
  });

  testWidgets('forced update shows a single 立即更新 action and stays open',
      (tester) async {
    final launched = <String>[];
    await _openDialog(tester, currentBuild: 1, onLaunch: launched.add);

    expect(find.byKey(const Key('app-update-forced-dialog')), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.byKey(const Key('app-update-defer')), findsNothing);
    expect(find.textContaining('必须更新'), findsOneWidget);

    // The system back path (gesture/button) must not dismiss the dialog.
    final navigator =
        Navigator.of(tester.element(find.byKey(const Key('app-update-forced-dialog'))));
    await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-update-forced-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-update-now')));
    await tester.pump();
    expect(launched.single, _info.apkUrl);
  });
}
