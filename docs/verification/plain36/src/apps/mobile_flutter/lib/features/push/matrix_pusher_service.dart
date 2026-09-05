import 'dart:async';

import 'package:matrix/matrix.dart';

import '../../core/notification/notification_diagnostics.dart';
import 'push_token_provider.dart';

/// Matrix pusher 网关抽象（测试替身注入；SDK Client 为具体类不可 mock）。
abstract interface class MatrixPusherGateway {
  Future<void> create(Pusher pusher);

  Future<void> delete(PusherId id);
}

/// matrix SDK 实现：`POST /_matrix/client/v3/pushers/set`。
final class ClientMatrixPusherGateway implements MatrixPusherGateway {
  ClientMatrixPusherGateway(this.client);

  final Client client;

  @override
  Future<void> create(Pusher pusher) => client.postPusher(pusher);

  @override
  Future<void> delete(PusherId id) => client.deletePusher(id);
}

/// Matrix Pusher 注册（kind=http，指向 Sygnal 推送网关）。
///
/// 载荷规范（E2EE 边界）：`format: event_id_only`——推送只含
/// eventId/roomId/未读数等不透明标识与通用文案，绝不含消息明文、
/// 附件名、房间密钥或恢复密钥；服务端 homeserver 同步配置
/// `push.include_content: false`（模板见 data/synapse/）。
final class MatrixPusherService {
  MatrixPusherService({
    required this.gateway,
    required this.tokenProvider,
    required this.appId,
    required this.gatewayUrl,
    this.deviceDisplayName = 'ChatFlow',
    NotificationDiagnostics? diagnostics,
  }) : diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  static const appIdAndroid = 'com.liuhetong.mobile.android';
  static const appIdIOS = 'com.liuhetong.mobile.ios';

  /// 个推通道（自建 getui-bridge 桥接；推送载荷仅通用文案，见
  /// services/getui-bridge 与 docs/PUSH_SETUP.md）。
  static const appIdGetui = 'com.liuhetong.mobile.getui';
  static const _pushFormat = 'event_id_only';

  final MatrixPusherGateway gateway;
  final PushTokenProvider tokenProvider;
  final String appId;
  final Uri? gatewayUrl;
  final String deviceDisplayName;
  final NotificationDiagnostics diagnostics;

  String? _registeredToken;
  StreamSubscription<String?>? _tokenSub;
  bool _unregistering = false;

  // ── C04：推送绑定归属到会话（generation） ──
  // 每次 unregister/dispose 递增；在途注册完成后发现代数变化即丢弃
  // 结果并补偿删除，迟到回调不能再排队重试——注销与注册竞态不会再
  // 把旧账号的 pusher 写回服务端。
  int _generation = 0;
  Future<bool>? _registrationInFlight;

  // ── 可恢复状态机 ──
  // 注册失败后有限指数退避自动重试；resume/网络恢复/CID 变化可手动触发。
  int _retryCount = 0;
  Timer? _retryTimer;
  bool _registering = false;
  DateTime? _lastSuccessAt;
  DateTime? _lastFailureAt;
  String _lastFailureKind = '';

  static const _retryDelays = <Duration>[
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
  ];

  bool get isRegistered => _registeredToken != null;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  DateTime? get lastFailureAt => _lastFailureAt;
  String get lastFailureKind => _lastFailureKind;

  /// 登录后调用：网关未配置或 token 不可得 → 不注册（安全降级）。
  /// token 与已注册值一致 → 幂等跳过；变化 → 重注册。
  /// 失败后有限指数退避自动重试；并发守卫防重复注册。
  Future<bool> ensureRegistered() async {
    if (_registering) return false;
    _registering = true;
    final generation = _generation;
    final future = _doRegister(generation);
    _registrationInFlight = future;
    try {
      return await future;
    } finally {
      _registering = false;
      if (identical(_registrationInFlight, future)) _registrationInFlight = null;
    }
  }

  Future<bool> _doRegister(int generation) async {
    if (generation != _generation) return false;
    final url = gatewayUrl;
    if (url == null) {
      diagnostics.record(
          NotificationDiagStage.push, 'gateway not configured; pusher off');
      return false;
    }
    final token = await tokenProvider.token();
    if (generation != _generation) return false;
    if (token == null || token.isEmpty) {
      _lastFailureKind = 'no-token';
      _lastFailureAt = DateTime.now();
      diagnostics.record(
          NotificationDiagStage.push, 'no device token; pusher off');
      if (generation == _generation) _scheduleRetry();
      return false;
    }
    if (token == _registeredToken) return true;
    try {
      await gateway.create(
        Pusher(
          appId: appId,
          pushkey: token,
          kind: 'http',
          appDisplayName: 'ChatFlow',
          deviceDisplayName: deviceDisplayName,
          lang: 'zh-CN',
          data: PusherData(format: _pushFormat, url: url),
        ),
      );
      if (generation != _generation) {
        // 注册完成时会话已注销/切换：服务端已存在该 pusher → 立即补偿
        // 删除，不把旧账号推送绑定留下来。
        try {
          await gateway.delete(PusherId(appId: appId, pushkey: token));
        } catch (_) {}
        return false;
      }
      _registeredToken = token;
      _lastSuccessAt = DateTime.now();
      _lastFailureKind = '';
      _retryCount = 0;
      _cancelRetry();
      diagnostics.record(NotificationDiagStage.push,
          'pusher registered (format=$_pushFormat)');
      return true;
    } catch (error) {
      if (generation != _generation) return false;
      _lastFailureKind = error.runtimeType.toString();
      _lastFailureAt = DateTime.now();
      diagnostics.record(
          NotificationDiagStage.push, 'register failed: ${error.runtimeType}');
      _scheduleRetry();
      return false;
    }
  }

  void _scheduleRetry() {
    if (_retryCount >= _retryDelays.length) {
      diagnostics.record(NotificationDiagStage.push,
          'pusher retry: exhausted ${_retryDelays.length} attempts; waiting for external trigger');
      return;
    }
    _retryTimer?.cancel();
    final delay = _retryDelays[_retryCount++];
    diagnostics.record(NotificationDiagStage.push,
        'pusher retry scheduled in ${delay.inSeconds}s (attempt $_retryCount/${_retryDelays.length})');
    _retryTimer = Timer(delay, () {
      if (_unregistering) return;
      unawaited(ensureRegistered());
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryCount = 0;
  }

  /// 外部触发重检查（resume/网络恢复/登录恢复）：不重置退避计数，
  /// 但立即尝试一次；若已在注册中则跳过。
  Future<void> recheck() async {
    if (isRegistered) {
      // 已注册：仅在有 CID 变化时重注册（token() 有等待逻辑会返回
      // 当前 CID，如果与已注册一致则幂等跳过）。
      await ensureRegistered();
      return;
    }
    _cancelRetry();
    await ensureRegistered();
  }

  /// Token 轮换监听：FCM 刷新 token 后自动重注册。
  Future<void> watchTokenRefresh() async {
    _tokenSub ??= tokenProvider.tokenUpdates().listen((token) {
      if (token == null || token.isEmpty) return;
      if (token == _registeredToken) return;
      unawaited(ensureRegistered());
    });
  }

  /// 登出/账号切换：注销 pusher（服务端停止向该设备推送）。
  ///
  /// C04：先递增会话代数使在途注册失效，**等待在途注册结束**后再删除；
  /// 若在途 create 在注销后才完成（迟到写入服务端），由 _doRegister 的
  /// 补偿删除清掉；迟到失败回调因代数不符不能再排队重试。
  Future<void> unregister() async {
    if (_unregistering) return;
    _unregistering = true;
    _generation++;
    _cancelRetry();
    try {
      // 等待在途注册收敛（注销不与注册竞态）。
      final inFlight = _registrationInFlight;
      if (inFlight != null) {
        await inFlight.catchError((_) => false);
      }
      final token = _registeredToken ?? await tokenProvider.token();
      if (token == null || token.isEmpty) {
        _registeredToken = null;
        return;
      }
      try {
        await gateway.delete(PusherId(appId: appId, pushkey: token));
        diagnostics.record(NotificationDiagStage.push, 'pusher deleted');
      } catch (error) {
        diagnostics.record(
            NotificationDiagStage.push, 'delete failed: ${error.runtimeType}');
      }
      _registeredToken = null;
    } finally {
      _unregistering = false;
    }
  }

  Future<void> dispose() async {
    _generation++;
    _cancelRetry();
    await _tokenSub?.cancel();
    _tokenSub = null;
  }
}
