import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/payment_pin/payment_pin_dialog.dart';

Future<void> digits(WidgetTester t, String value) async {
  for (final digit in value.split('')) {
    await t.tap(find.byKey(ValueKey('payment-pin-key-$digit')));
    await t.pump();
  }
}

void main() {
  testWidgets('system back during request cannot pop the underlying draft',
      (t) async {
    final pending = Completer<String>();
    final navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(
        CupertinoApp(navigatorKey: navigator, home: const Text('home')));
    unawaited(navigator.currentState!.push<void>(CupertinoPageRoute(
        builder: (_) =>
            const CupertinoPageScaffold(child: Center(child: Text('draft'))))));
    await t.pumpAndSettle();
    final result = showPaymentPinAuthorization(navigator.currentContext!,
        title: '确认转账',
        recipient: '测试好友',
        amount: '1.00',
        onAuthorize: (_) => pending.future);
    await t.pumpAndSettle();
    await digits(t, '123456');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pump();
    await navigator.currentState!.maybePop();
    // Complete while the popped route is still mounted for its exit animation.
    pending.complete('late-proof');
    await t.pump();
    await t.pumpAndSettle();
    expect(await result, isNull);
    expect(find.text('draft'), findsOneWidget);
    expect(navigator.currentState!.canPop(), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('cancel setup returns false without calling setup', (t) async {
    var calls = 0;
    bool? result;
    await t.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () async {
                  result = await showPaymentPinSetup(context,
                      onSetup: (pin, password) async {
                    calls++;
                  });
                }))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(result, false);
    expect(calls, 0);
  });

  testWidgets('changed account aborts before authorization callback',
      (t) async {
    var calls = 0;
    await t.pumpWidget(CupertinoApp(
        home: PaymentPinPage.authorize(
      title: '确认转账',
      recipient: '测试好友',
      amount: '1.00',
      onAuthorize: (_) async {
        calls++;
        return 'proof';
      },
      isScopeCurrent: () async => false,
    )));
    await digits(t, '123456');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('●'), findsNothing);
  });

  testWidgets('closing during request discards late authorization result',
      (t) async {
    final pending = Completer<String>();
    String? result = 'unresolved';
    await t.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () async {
                  result = await showPaymentPinAuthorization(context,
                      title: '确认转账',
                      recipient: '测试好友',
                      amount: '1.00',
                      onAuthorize: (_) => pending.future);
                }))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await digits(t, '123456');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pump();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    pending.complete('late-proof');
    await t.pumpAndSettle();
    expect(result, isNull);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'background hides PIN and unknown error never exposes exception text',
      (t) async {
    await t.pumpWidget(CupertinoApp(
        home: PaymentPinPage.authorize(
      title: '确认转账',
      recipient: '测试好友',
      amount: '1.00',
      onAuthorize: (pin) async => throw StateError('sensitive-$pin'),
    )));
    await digits(t, '123456');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(find.text('●'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    await digits(t, '123456');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pumpAndSettle();
    expect(find.text('操作未完成，请稍后重试'), findsOneWidget);
    expect(find.textContaining('sensitive'), findsNothing);
  });

  testWidgets(
      'six digits preserve zero, cap input and require explicit confirm',
      (t) async {
    final values = <String>[];
    await t.pumpWidget(CupertinoApp(
        home: PaymentPinPage.authorize(
      title: '确认转账',
      recipient: '测试好友',
      amount: '1.00 彩币',
      onAuthorize: (pin) async {
        values.add(pin);
        return 'proof';
      },
    )));
    expect(find.byType(CupertinoTextField), findsNothing);
    await digits(t, '01234');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    expect(values, isEmpty);
    await digits(t, '567');
    expect(values, isEmpty);
    expect(find.text('●'), findsNWidgets(6));
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pumpAndSettle();
    expect(values, ['012345']);
  });

  testWidgets('delete, clear and server error erase input; no duplicate submit',
      (t) async {
    final pending = Completer<String>();
    var calls = 0;
    await t.pumpWidget(CupertinoApp(
        home: PaymentPinPage.authorize(
      title: '发红包',
      recipient: '测试群',
      amount: '1.00',
      onAuthorize: (_) {
        calls++;
        return pending.future;
      },
    )));
    await digits(t, '123');
    await t.tap(find.byKey(const ValueKey('payment-pin-key-delete')));
    await t.pump();
    expect(find.text('●'), findsNWidgets(2));
    await t.tap(find.byKey(const ValueKey('payment-pin-key-clear')));
    await t.pump();
    expect(find.text('●'), findsNothing);
    await digits(t, '123456');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    expect(calls, 1);
    pending.completeError(const PaymentPinException('密码错误，还可尝试4次'));
    await t.pumpAndSettle();
    expect(find.text('●'), findsNothing);
    expect(find.text('密码错误，还可尝试4次'), findsOneWidget);
  });

  testWidgets('setup requires matching confirmation and login credential',
      (t) async {
    final values = <String>[];
    await t.pumpWidget(CupertinoApp(home: PaymentPinPage.setup(
      onSetup: (pin, password) async {
        values.add('$pin:$password');
      },
    )));
    await t.enterText(find.byType(CupertinoTextField), 'test-login');
    await t.pump();
    await t.tap(find.text('下一步'));
    await t.pumpAndSettle();
    await digits(t, '012345');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pump();
    await digits(t, '123456');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pump();
    expect(values, isEmpty);
    expect(find.text('两次密码不一致，请重新输入'), findsOneWidget);
    expect(find.text('●'), findsNothing);
    await digits(t, '012345');
    await t.tap(find.byKey(const ValueKey('payment-pin-confirm')));
    await t.pumpAndSettle();
    expect(values, ['012345:test-login']);
  });

  testWidgets(
      'small screen and enlarged text remain scrollable without overflow',
      (t) async {
    t.view.physicalSize = const Size(320, 480);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(CupertinoApp(
        home: MediaQuery(
      data: const MediaQueryData(
          size: Size(320, 480), textScaler: TextScaler.linear(1.6)),
      child: PaymentPinPage.authorize(
          title: '确认转账',
          recipient: '很长的测试收款对象名称',
          amount: '123456789.00 彩币',
          onAuthorize: (_) async => 'proof'),
    )));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.ensureVisible(find.byKey(const ValueKey('payment-pin-confirm')));
    expect(t.takeException(), isNull);
  });
}
