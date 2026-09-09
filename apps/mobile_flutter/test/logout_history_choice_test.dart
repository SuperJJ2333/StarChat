import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

void main() {
  testWidgets('logout keeps initial confirmation then offers default save',
      (tester) async {
    var logouts = 0;
    var clears = 0;
    await tester.pumpWidget(CupertinoApp(
        home: SettingsPage(
      api: BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: SecureSessionStore()),
      onLogout: () async {
        logouts++;
      },
      onClearLocalChatData: () async {
        clears++;
      },
    )));
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoDialogAction, '退出登录'));
    await tester.pumpAndSettle();
    expect(logouts, 0);
    expect(find.text('是否删除本机聊天记录？'), findsOneWidget);
    final save = tester.widget<CupertinoDialogAction>(
        find.widgetWithText(CupertinoDialogAction, '保存'));
    expect(save.isDefaultAction, isTrue);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(logouts, 1);
    expect(clears, 0);
  });
  for (final failure in [false, true]) {
    testWidgets('delete waits for clear, resets busy on failure=$failure',
        (tester) async {
      final events = <String>[];
      final pending = Completer<void>();
      await tester.pumpWidget(CupertinoApp(
          home: SettingsPage(
        api: BusinessApiClient(
            baseUri: Uri.parse('https://business.test'),
            sessionStore: SecureSessionStore()),
        onClearLocalChatData: () {
          events.add('clear');
          return pending.future;
        },
        onLogout: () async {
          events.add('logout');
        },
      )));
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CupertinoDialogAction, '退出登录'));
      await tester.pumpAndSettle();
      final delete = tester.widget<Text>(find.text('确认删除'));
      expect(delete.style?.fontWeight, FontWeight.bold);
      expect(delete.style?.color, CupertinoColors.systemRed);
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(events, ['clear']);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      if (failure) {
        pending.completeError(StateError('local failure'));
        await tester.pumpAndSettle();
        expect(find.text('已退出登录，本机数据未完全删除'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        expect(events, ['clear', 'logout']);
      } else {
        pending.complete();
        await tester.pumpAndSettle();
        expect(events, ['clear', 'logout']);
      }
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    });
  }
  testWidgets('cancel second choice retains account and history',
      (tester) async {
    var actions = 0;
    await tester.pumpWidget(CupertinoApp(
        home: SettingsPage(
      api: BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: SecureSessionStore()),
      onLogout: () async {
        actions++;
      },
      onClearLocalChatData: () async {
        actions++;
      },
    )));
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoDialogAction, '退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(actions, 0);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
  });
  testWidgets(
      'deleting continues logout after settings is removed by resource teardown',
      (tester) async {
    final visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    final pending = Completer<void>();
    var logouts = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (_, showSettings, __) => showSettings
          ? SettingsPage(
              api: BusinessApiClient(
                  baseUri: Uri.parse('https://business.test'),
                  sessionStore: SecureSessionStore()),
              onClearLocalChatData: () {
                visible.value = false;
                return pending.future;
              },
              onLogout: () async {
                logouts++;
              },
            )
          : const Text('Login page'),
    )));
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoDialogAction, '退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
    expect(logouts, 1);
    expect(find.text('Login page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed deletion shows truthful notice after Settings teardown',
      (tester) async {
    final visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    final pending = Completer<void>();
    var logouts = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (_, showSettings, __) => showSettings
          ? SettingsPage(
              api: BusinessApiClient(
                  baseUri: Uri.parse('https://business.test'),
                  sessionStore: SecureSessionStore()),
              onClearLocalChatData: () {
                visible.value = false;
                return pending.future;
              },
              onLogout: () async {
                logouts++;
              },
            )
          : const Text('Login page'),
    )));
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoDialogAction, '退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    pending.completeError(StateError('disk failure'));
    await tester.pumpAndSettle();
    expect(logouts, 1);
    expect(find.text('已退出登录，本机数据未完全删除'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(find.text('Login page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final choice in ['保存', '确认删除']) {
    testWidgets('$choice reaches login page without a leftover modal',
        (tester) async {
      final authenticated = ValueNotifier<bool>(true);
      addTearDown(authenticated.dispose);
      var clears = 0;
      await tester.pumpWidget(CupertinoApp(
          home: ValueListenableBuilder<bool>(
        valueListenable: authenticated,
        builder: (_, signedIn, __) => signedIn
            ? SettingsPage(
                api: BusinessApiClient(
                    baseUri: Uri.parse('https://business.test'),
                    sessionStore: SecureSessionStore()),
                onClearLocalChatData: () async {
                  clears++;
                },
                onLogout: () async {
                  authenticated.value = false;
                },
              )
            : const Text('Login page'),
      )));
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CupertinoDialogAction, '退出登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(find.text('Login page'), findsOneWidget);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(clears, choice == '保存' ? 0 : 1);
      expect(tester.takeException(), isNull);
    });
  }
}
