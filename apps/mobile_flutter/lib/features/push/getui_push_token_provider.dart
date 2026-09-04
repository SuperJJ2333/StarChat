import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/notification/notification_diagnostics.dart';
import 'push_token_provider.dart';

/// 个推 Token（CID）提供方。
///
/// 隐私门槛（构造前由组合根检查，本类不重复判断）：
/// 1. 仅 Android；
/// 2. 用户已持久化同意隐私政策（PrivacyConsentStore）——同意前 SDK 只
///    处于 preInit 状态（无采集无联网）；
/// 3. 未同意/初始化失败 → token 为 null，不注册 pusher，聊天不受影响。
///
/// CID 即 Matrix pusher 的 pushkey（设备级绑定；登出=删 pusher，
/// 绝不做手机号/用户名 alias）。
///
/// CID 竞态修复：PushManager.initialize 后 CID 异步返回（可能数秒）。
/// [token] 在 CID 为空时短暂等待（轮询 ≤ [cidWaitTimeout]），避免
/// 首次注册时永远拿到 null；[tokenUpdates] 依赖原生 onListen 回放 +
/// CID 事件补注册。initialize 失败可重试（不一旦置 true）。
final class GetuiPushTokenProvider implements PushTokenProvider {
  GetuiPushTokenProvider({NotificationDiagnostics? diagnostics})
      : diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  static const _methodChannel = MethodChannel('chatflow/getui');
  static const _eventChannel = EventChannel('chatflow/getui/events');

  /// CID 等待上限（个推 SDK 在网络正常时数秒内返回 CID）。
  static const cidWaitTimeout = Duration(seconds: 8);
  static const _cidPollInterval = Duration(milliseconds: 500);

  final NotificationDiagnostics diagnostics;

  /// null=未尝试；true=成功；false=上次失败（可重试）。
  bool? _initResult;
  StreamSubscription<dynamic>? _events;

  /// 第二段初始化（preInit 已在 Application 完成且无需同意）。
  /// 必须在持久化同意之后调用。失败后置 false，允许后续重试。
  Future<bool> initialize() async {
    if (_initResult == true) return true;
    try {
      final ok = await _methodChannel.invokeMethod<bool>('initialize');
      _initResult = ok == true;
      diagnostics.record(
          NotificationDiagStage.push, 'getui initialize: ${ok == true}');
      return _initResult!;
    } catch (error) {
      _initResult = false;
      diagnostics.record(NotificationDiagStage.push,
          'getui initialize failed: ${error.runtimeType}');
      return false;
    }
  }

  bool get isInitialized => _initResult == true;

  /// CID 存在性探针（诊断页用）：单次查询不等待；只回答有/无，
  /// 调用方绝不渲染返回的原值。
  Future<bool> hasCid() async {
    final cid = await _invokeGetCid();
    return cid != null && cid.isNotEmpty;
  }

  @override
  Future<String?> token() async {
    if (_initResult != true) return null;
    final deadline = DateTime.now().add(cidWaitTimeout);
    while (true) {
      final cid = await _invokeGetCid();
      if (cid != null && cid.isNotEmpty) return cid;
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(_cidPollInterval);
    }
  }

  Future<String?> _invokeGetCid() async {
    try {
      return await _methodChannel.invokeMethod<String>('getCid');
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<String?> tokenUpdates() => _eventChannel.receiveBroadcastStream().map(
        (event) {
          if (event is Map && event['type'] == 'cid') {
            final cid = event['cid'];
            return cid is String && cid.isNotEmpty ? cid : null;
          }
          return null;
        },
      ).where((cid) => cid != null);

  @override
  Future<void> dispose() async {
    await _events?.cancel();
    _events = null;
  }
}
