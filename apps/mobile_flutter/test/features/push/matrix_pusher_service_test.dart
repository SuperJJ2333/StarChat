import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_diagnostics.dart';
import 'package:liuhetong_mobile/features/push/matrix_pusher_service.dart';
import 'package:liuhetong_mobile/features/push/push_token_provider.dart';
import 'package:matrix/matrix.dart';

void main() {
  late _RecordingPusherGateway gateway;
  late _FakeTokenProvider tokens;
  late NotificationDiagnostics diagnostics;

  setUp(() {
    gateway = _RecordingPusherGateway();
    tokens = _FakeTokenProvider('token-1');
    diagnostics = NotificationDiagnostics(store: _MemoryDiagStore());
  });

  MatrixPusherService service({Uri? gatewayUrl}) => MatrixPusherService(
        gateway: gateway,
        tokenProvider: tokens,
        appId: MatrixPusherService.appIdAndroid,
        gatewayUrl: gatewayUrl ??
            Uri.parse('https://sygnal.example.test/_matrix/push/v1/notify'),
        diagnostics: diagnostics,
      );

  test('登录后注册 pusher：kind=http、format=event_id_only、指向网关', () async {
    final pusher = service();
    expect(await pusher.ensureRegistered(), isTrue);
    expect(gateway.created, hasLength(1));
    final created = gateway.created.single;
    expect(created.kind, 'http');
    expect(created.pushkey, 'token-1');
    expect(created.appId, MatrixPusherService.appIdAndroid);
    expect(created.data.format, 'event_id_only');
    expect(created.data.url.toString(),
        'https://sygnal.example.test/_matrix/push/v1/notify');
  });

  test('E2EE 边界：pusher 数据只含 format/url，不含任何内容字段', () async {
    await service().ensureRegistered();
    final data = gateway.created.single.data.toJson();
    expect(data.keys.toSet(), {'format', 'url'}, reason: '推送配置不得携带正文/密钥类字段');
  });

  test('个推网关使用 Synapse 强制的标准路径，以查询参数选择通道', () async {
    final url = MatrixPusherService.getuiGatewayUrl(
      Uri.parse('https://push.example.test/'),
    );
    expect(url.path, '/_matrix/push/v1/notify');
    expect(url.queryParameters, {'provider': 'getui'});
    final pusher = MatrixPusherService(
      gateway: gateway,
      tokenProvider: tokens,
      appId: MatrixPusherService.appIdGetui,
      gatewayUrl: url,
      diagnostics: diagnostics,
    );
    expect(await pusher.ensureRegistered(), isTrue);
    expect(gateway.created.single.data.url, url);
    expect(gateway.created.single.data.format, 'event_id_only');
    expect(
        gateway.created.single.data.toJson().keys.toSet(), {'format', 'url'});
  });

  test('网关未配置：不注册并留下诊断（安全降级）', () async {
    final pusher = MatrixPusherService(
      gateway: gateway,
      tokenProvider: tokens,
      appId: MatrixPusherService.appIdAndroid,
      gatewayUrl: null,
      diagnostics: diagnostics,
    );
    expect(await pusher.ensureRegistered(), isFalse);
    expect(gateway.created, isEmpty);
    expect(
      diagnostics.snapshot().any((e) => e.stage == NotificationDiagStage.push),
      isTrue,
    );
  });

  test('无设备 Token：不注册（FCM 凭据缺失场景）', () async {
    tokens.value = null;
    expect(await service().ensureRegistered(), isFalse);
    expect(gateway.created, isEmpty);
  });

  test('相同 Token 幂等；Token 轮换自动重注册', () async {
    final pusher = service();
    await pusher.ensureRegistered();
    await pusher.ensureRegistered();
    expect(gateway.created, hasLength(1));

    await pusher.watchTokenRefresh();
    tokens.emit('token-2');
    await Future<void>.delayed(Duration.zero);
    expect(gateway.created, hasLength(2));
    expect(gateway.created.last.pushkey, 'token-2');
  });

  test('登出注销：deletePusher 携带 appId+pushkey；无 Token 时不误删', () async {
    final pusher = service();
    await pusher.ensureRegistered();
    await pusher.unregister();
    expect(gateway.deleted, hasLength(1));
    expect(gateway.deleted.single.appId, MatrixPusherService.appIdAndroid);
    expect(gateway.deleted.single.pushkey, 'token-1');
    expect(pusher.isRegistered, isFalse);

    gateway.deleted.clear();
    tokens.value = null;
    await pusher.unregister();
    expect(gateway.deleted, isEmpty);
  });

  test('注册失败（服务端异常）：不抛出、不进入已注册态、可重试', () async {
    gateway.failCreate = true;
    final pusher = service();
    expect(await pusher.ensureRegistered(), isFalse);
    expect(pusher.isRegistered, isFalse);
    gateway.failCreate = false;
    expect(await pusher.ensureRegistered(), isTrue);
  });

  test('C04：create 在途时注销 → 等待收敛+补偿删除，无旧账号 pusher', () async {
    var createEntered = false;
    final entered = Completer<void>();
    final gateway = _GatedPusherGateway()
      ..gateCreate = Completer<void>()
      ..onCreateEntered = () {
        createEntered = true;
        if (!entered.isCompleted) entered.complete();
      };
    final pusher = MatrixPusherService(
      gateway: gateway,
      tokenProvider: _FakeTokenProvider('cid-A'),
      appId: MatrixPusherService.appIdGetui,
      gatewayUrl: Uri.parse('https://push.example.test/notify'),
    );
    final registering = pusher.ensureRegistered();
    // 等 create 已发出（在途）后再注销——覆盖"注销与在途注册竞态"。
    await entered.future;
    expect(createEntered, isTrue);
    final unregistering = pusher.unregister();
    // 放行迟到的 create：注册完成后发现代数已失效 → 补偿删除。
    gateway.gateCreate!.complete();
    await unregistering;
    expect(await registering, isFalse, reason: '注销后代数失效：注册结果被丢弃');
    expect(pusher.isRegistered, isFalse,
        reason: '迟到 create 不得把旧 pusher 写回本地状态');
    // 服务端净效果：create 之后必须跟随删除（补偿删除/注销删除），
    // 最终不残留旧账号 pusher。
    expect(gateway.created.length, 1);
    expect(gateway.deleted.isNotEmpty, isTrue,
        reason: '迟到 create 的 pusher 已被清理');
  });

  test('C04：dispose 后失败回调不能再排队重试', () async {
    final failing = _RecordingPusherGateway()..failCreate = true;
    final pusher = MatrixPusherService(
      gateway: failing,
      tokenProvider: _FakeTokenProvider('cid-B'),
      appId: MatrixPusherService.appIdGetui,
      gatewayUrl: Uri.parse('https://push.example.test/notify'),
    );
    expect(await pusher.ensureRegistered(), isFalse);
    await pusher.dispose();
    final createsBefore = failing.created.length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(failing.created.length, createsBefore, reason: 'dispose 后不得再尝试注册');
  });
}

final class _RecordingPusherGateway implements MatrixPusherGateway {
  final created = <Pusher>[];
  final deleted = <PusherId>[];
  var failCreate = false;

  @override
  Future<void> create(Pusher pusher) async {
    if (failCreate) throw Exception('synapse 502');
    created.add(pusher);
  }

  @override
  Future<void> delete(PusherId id) async => deleted.add(id);
}

final class _FakeTokenProvider implements PushTokenProvider {
  _FakeTokenProvider(String? initial) : value = initial;

  String? value;
  final _controller = StreamController<String?>.broadcast();

  void emit(String? next) {
    value = next;
    _controller.add(next);
  }

  @override
  Future<String?> token() async => value;

  @override
  Stream<String?> tokenUpdates() => _controller.stream;

  @override
  Future<void> dispose() => _controller.close();
}

final class _MemoryDiagStore implements NotificationDiagStore {
  String? _encoded;

  @override
  Future<String?> read() async => _encoded;

  @override
  Future<void> write(String encoded) async => _encoded = encoded;
}

// ── C04：推送注册与退出注销的异步竞态 ──────────────────────────

final class _GatedPusherGateway implements MatrixPusherGateway {
  final created = <Pusher>[];
  final deleted = <PusherId>[];
  Completer<void>? gateCreate;
  void Function()? onCreateEntered;

  @override
  Future<void> create(Pusher pusher) async {
    onCreateEntered?.call();
    final gate = gateCreate;
    if (gate != null) await gate.future;
    created.add(pusher);
  }

  @override
  Future<void> delete(PusherId id) async => deleted.add(id);
}
