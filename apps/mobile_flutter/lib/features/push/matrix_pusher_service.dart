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

  bool get isRegistered => _registeredToken != null;

  /// 登录后调用：网关未配置或 token 不可得 → 不注册（安全降级）。
  /// token 与已注册值一致 → 幂等跳过；变化 → 重注册。
  Future<bool> ensureRegistered() async {
    final url = gatewayUrl;
    if (url == null) {
      diagnostics.record(
          NotificationDiagStage.push, 'gateway not configured; pusher off');
      return false;
    }
    final token = await tokenProvider.token();
    if (token == null || token.isEmpty) {
      diagnostics.record(
          NotificationDiagStage.push, 'no device token; pusher off');
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
      _registeredToken = token;
      diagnostics.record(NotificationDiagStage.push,
          'pusher registered (format=$_pushFormat)');
      return true;
    } catch (error) {
      diagnostics.record(
          NotificationDiagStage.push, 'register failed: ${error.runtimeType}');
      return false;
    }
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
  Future<void> unregister() async {
    if (_unregistering) return;
    _unregistering = true;
    try {
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
    await _tokenSub?.cancel();
    _tokenSub = null;
  }
}
