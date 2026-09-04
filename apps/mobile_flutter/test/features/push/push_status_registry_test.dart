import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/privacy_consent.dart';
import 'package:liuhetong_mobile/features/push/getui_push_token_provider.dart';
import 'package:liuhetong_mobile/features/push/matrix_pusher_service.dart';
import 'package:liuhetong_mobile/features/push/push_status_registry.dart';
import 'package:liuhetong_mobile/features/push/push_token_provider.dart';
import 'package:liuhetong_mobile/features/settings/notification/notification_diagnostics_page.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _getuiChannel = MethodChannel('chatflow/getui');
const _permissionChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');

class _RecordingPusherGateway implements MatrixPusherGateway {
  _RecordingPusherGateway({this.failCreate = false});
  final bool failCreate;
  final created = <Pusher>[];

  @override
  Future<void> create(Pusher pusher) async {
    if (failCreate) throw Exception('gateway down');
    created.add(pusher);
  }

  @override
  Future<void> delete(PusherId id) async {}
}

class _FakeTokenProvider implements PushTokenProvider {
  _FakeTokenProvider(this.value);
  String? value;

  @override
  Future<String?> token() async => value;

  @override
  Stream<String?> tokenUpdates() => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

class _FakeConsentStore implements PrivacyConsentStore {
  _FakeConsentStore(this.ok);
  bool ok;

  @override
  Future<bool> accepted() async => ok;

  @override
  Future<void> accept() async => ok = true;
}

Future<void> _mockGetui({String? cid, bool initOk = true}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_getuiChannel, (call) async {
    switch (call.method) {
      case 'initialize':
        return initOk;
      case 'getCid':
        return cid;
    }
    return null;
  });
}

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .join('\n');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // permission_handler 平台通道必须 mock（测试环境无插件响应者，
    // 不 mock 会让权限查询 Future 永不完成）。1 = PermissionStatus.granted。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, (call) async => 1);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_getuiChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, null);
  });

  test('注册表：登记 pusher 服务与清空（登出不留旧账号通道）', () {
    final registry = PushStatusRegistry();
    final service = MatrixPusherService(
      gateway: _RecordingPusherGateway(),
      tokenProvider: _FakeTokenProvider('t'),
      appId: MatrixPusherService.appIdGetui,
      gatewayUrl: Uri.parse('https://push.example.test/_matrix/push/v1/getui/notify'),
    );
    registry.register(service);
    expect(registry.services, hasLength(1));
    registry.clear();
    expect(registry.services, isEmpty);
  });

  testWidgets('诊断页：个推通道完整状态行；CID 只显示存在性（脱敏红线）',
      (tester) async {
    await _mockGetui(cid: 'SECRET-cid-must-not-leak');
    final provider = GetuiPushTokenProvider();
    await provider.initialize();
    final gateway = _RecordingPusherGateway();
    final service = MatrixPusherService(
      gateway: gateway,
      tokenProvider: provider,
      appId: MatrixPusherService.appIdGetui,
      gatewayUrl:
          Uri.parse('https://push.example.test/_matrix/push/v1/getui/notify'),
    );
    expect(await service.ensureRegistered(), isTrue);
    final registry = PushStatusRegistry()..register(service);

    await tester.pumpWidget(CupertinoApp(
      home: NotificationDiagnosticsPage(
        registry: registry,
        consentStore: _FakeConsentStore(true),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final text = _allText(tester);
    expect(text, contains('隐私同意'), reason: '必须显示隐私同意状态');
    expect(text, contains('已同意'));
    expect(text, contains('已初始化'), reason: 'SDK 初始化状态行');
    expect(text, contains('已获取'), reason: 'CID 存在性行');
    expect(text, contains('已注册'), reason: 'pusher 注册状态行');
    expect(text, contains('push.example.test'), reason: '网关主机可见');
    expect(text, contains('通知权限'), reason: '通知权限状态行');
    expect(text, contains('电池优化'), reason: '电池优化状态行');
    // 脱敏红线：原始 CID 绝不出现在 UI。
    expect(text.contains('SECRET-cid-must-not-leak'), isFalse,
        reason: 'CID 原值不得渲染');
    await service.dispose();
  });

  testWidgets('诊断页：未同意/未初始化/未注册/失败类别全部可见', (tester) async {
    await _mockGetui(cid: null, initOk: false);
    final provider = GetuiPushTokenProvider();
    final failingGateway = _RecordingPusherGateway(failCreate: true);
    final service = MatrixPusherService(
      gateway: failingGateway,
      tokenProvider: provider,
      appId: MatrixPusherService.appIdGetui,
      gatewayUrl:
          Uri.parse('https://push.example.test/_matrix/push/v1/getui/notify'),
    );
    expect(await service.ensureRegistered(), isFalse);
    final registry = PushStatusRegistry()..register(service);

    await tester.pumpWidget(CupertinoApp(
      home: NotificationDiagnosticsPage(
        registry: registry,
        consentStore: _FakeConsentStore(false),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final text = _allText(tester);
    expect(text, contains('未同意'));
    expect(text, contains('未初始化'));
    expect(text, contains('未获取'), reason: 'CID 缺失可见');
    expect(text, contains('未注册'));
    expect(text, contains('no-token'), reason: '失败类别可见（未初始化→no-token）');
    expect(text.contains('gateway down'), isFalse, reason: '失败详情不落 UI，只留类别');
    await service.dispose();
  });

  testWidgets('诊断页：非个推通道不显示 SDK/CID 行（该行仅个推适用）',
      (tester) async {
    await _mockGetui(cid: 'SECRET-cid-must-not-leak');
    final service = MatrixPusherService(
      gateway: _RecordingPusherGateway(),
      tokenProvider: _FakeTokenProvider('fcm-token'),
      appId: MatrixPusherService.appIdAndroid,
      gatewayUrl: Uri.parse('https://sygnal.example.test/_matrix/push/v1/notify'),
    );
    await service.ensureRegistered();
    final registry = PushStatusRegistry()..register(service);

    await tester.pumpWidget(CupertinoApp(
      home: NotificationDiagnosticsPage(
        registry: registry,
        consentStore: _FakeConsentStore(true),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final text = _allText(tester);
    expect(text, contains('已注册'));
    expect(text.contains('SDK 初始化'), isFalse,
        reason: 'SDK/CID 行只对个推通道渲染');
    expect(text.contains('fcm-token'), isFalse, reason: 'pushkey 原值不落 UI');
    await service.dispose();
  });
}
