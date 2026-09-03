import 'dart:async';

/// 推送 Token 提供方：FCM/APNs 就绪时返回设备 Token 并监听轮换；
/// 凭据未配置时返回 null（调用方据此不注册 Matrix pusher）。
abstract interface class PushTokenProvider {
  Future<String?> token();

  /// Token 轮换（FCM 会不定期刷新；刷新后必须重新注册 pusher）。
  Stream<String?> tokenUpdates();

  Future<void> dispose();
}

/// 默认实现：无推送配置（FCM 凭据缺失/平台不支持）。
/// token 恒为 null → MatrixPusherService 不注册 pusher，
/// Matrix 同步通道（前台服务保活）照常工作。
final class NoopPushTokenProvider implements PushTokenProvider {
  @override
  Future<String?> token() async => null;

  @override
  Stream<String?> tokenUpdates() => const Stream.empty();

  @override
  Future<void> dispose() async {}
}
