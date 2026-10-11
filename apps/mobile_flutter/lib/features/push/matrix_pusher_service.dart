import 'dart:async';
import 'dart:convert';

import 'package:matrix/matrix.dart';

import '../../core/notification/notification_diagnostics.dart';
import 'push_token_provider.dart';

/// Matrix pusher 网关抽象（测试替身注入；SDK Client 为具体类不可 mock）。
abstract interface class MatrixPusherGateway {
  Future<List<Pusher>> list();

  Future<void> create(Pusher pusher);

  Future<void> delete(PusherId id);
}

/// matrix SDK 实现：`POST /_matrix/client/v3/pushers/set`。
final class ClientMatrixPusherGateway implements MatrixPusherGateway {
  ClientMatrixPusherGateway(this.client);

  final Client client;

  @override
  Future<List<Pusher>> list() async =>
      await client.getPushers() ??
      (throw StateError('pusher list unavailable'));

  @override
  Future<void> create(Pusher pusher) => client.postPusher(pusher);

  @override
  Future<void> delete(PusherId id) => client.deletePusher(id);
}

// Matrix's default append=false moves an app/token binding between accounts.
// Serialize that remote resource across gateways, including compensating writes.
// Entries exist only while a service/operation leases them; cap exceptional churn.
final class _PusherBinding {
  static final _active = <(String, String), _PusherBinding>{};
  static int nextOwner = 0;
  static _PusherBinding acquire(String app, String token) {
    final key = (app, token);
    var binding = _active[key];
    if (binding == null) {
      if (_active.length >= 64) throw StateError('pusher binding capacity');
      binding = _PusherBinding(key);
      _active[key] = binding;
    }
    // A service has at most one in-flight write. Limit leases for one shared
    // token as well as distinct tokens so overload cannot grow its queue.
    if (binding.references >= 64) throw StateError('pusher owner capacity');
    binding.references++;
    return binding;
  }

  _PusherBinding(this.key);
  final (String, String) key;
  int references = 0;
  int owner = 0;
  Future<void> _tail = Future.value();
  Future<T> write<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void release() {
    if (--references == 0) _active.remove(key);
  }
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
    this.nativeMetadata,
    this.iosSoundEnabled,
    DateTime Function()? now,
    NotificationDiagnostics? diagnostics,
  })  : now = now ?? DateTime.now,
        diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  static const appIdAndroid = 'com.liuhetong.mobile.android';
  static const appIdIOS = 'com.liuhetong.mobile.ios';

  /// 个推通道（自建 getui-bridge 桥接；推送载荷仅通用文案，见
  /// services/getui-bridge 与 docs/PUSH_SETUP.md）。
  static const appIdGetui = 'com.liuhetong.mobile.getui';

  /// Synapse validates this exact path; a query selects the Getui upstream
  /// without changing the Matrix Push Gateway protocol or E2EE payload.
  static Uri getuiGatewayUrl(Uri base) => base.replace(
        path: '/_matrix/push/v1/notify',
        queryParameters: const {'provider': 'getui'},
      ).removeFragment();

  static const _pushFormat = 'event_id_only';

  final MatrixPusherGateway gateway;
  final PushTokenProvider tokenProvider;
  final String appId;
  final Uri? gatewayUrl;
  final String deviceDisplayName;
  final Map<String, Object>? Function()? nativeMetadata;
  final bool Function()? iosSoundEnabled;
  final NotificationDiagnostics diagnostics;
  final DateTime Function() now;
  static const verificationInterval = Duration(minutes: 5);

  String? _registeredToken;
  String? _registeredIdentity;
  final int _owner = ++_PusherBinding.nextOwner;
  _PusherBinding? _binding;
  bool _disposed = false;
  bool _dirty = false;
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
  DateTime? _lastRemoteVerifiedAt;
  DateTime? _nextRetryAt;
  bool _remoteKnown = false;
  bool _forceRemoteCheck = false;
  bool _checkingRemote = false;
  Timer? _verificationTimer;

  static const _retryDelays = <Duration>[
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  bool get isRegistered => _registeredToken != null;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  DateTime? get lastRemoteVerifiedAt => _lastRemoteVerifiedAt;
  bool get isRemoteVerified =>
      !_disposed &&
      !_unregistering &&
      _binding?.owner == _owner &&
      _remoteKnown &&
      _lastRemoteVerifiedAt != null &&
      now().difference(_lastRemoteVerifiedAt!) < verificationInterval;
  DateTime? get lastFailureAt => _lastFailureAt;
  String get lastFailureKind => _lastFailureKind;

  /// 登录后调用：网关未配置或 token 不可得 → 不注册（安全降级）。
  /// token 与已注册值一致 → 幂等跳过；变化 → 重注册。
  /// 失败后有限指数退避自动重试；并发守卫防重复注册。
  Future<bool> ensureRegistered() async {
    if (_unregistering || _disposed) return false;
    if (_registering) {
      _dirty = true;
      return _registrationInFlight!;
    }
    _registering = true;
    final generation = _generation;
    final future = _converge(generation);
    _registrationInFlight = future;
    try {
      return await future;
    } finally {
      _registering = false;
      if (identical(_registrationInFlight, future)) {
        _registrationInFlight = null;
      }
    }
  }

  Future<bool> _converge(int generation) async {
    var result = false;
    do {
      _dirty = false;
      result = await _doRegister(generation);
    } while (
        _dirty && generation == _generation && !_disposed && !_unregistering);
    return result;
  }

  _PusherBinding _lease(String token) {
    if (_binding?.key != (appId, token)) {
      final next = _PusherBinding.acquire(appId, token);
      _binding?.release();
      _binding = next;
    }
    return _binding!;
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
      _lastFailureAt = now();
      _remoteKnown = false;
      diagnostics.record(
          NotificationDiagStage.push, 'no device token; pusher off');
      if (generation == _generation) _scheduleRetry();
      return false;
    }
    final metadata = nativeMetadata?.call();
    if (nativeMetadata != null && metadata == null) return false;
    final audible =
        appId == appIdIOS ? (iosSoundEnabled?.call() ?? true) : null;
    final identity = jsonEncode([token, metadata, audible]);
    try {
      final binding = _lease(token);
      if (binding.owner > _owner) return false;
      binding.owner = _owner;
      return await binding.write(() async {
        if (generation != _generation || binding.owner != _owner) return false;
        final desired = Pusher(
          appId: appId,
          pushkey: token,
          kind: 'http',
          appDisplayName: 'ChatFlow',
          deviceDisplayName: deviceDisplayName,
          lang: 'zh-CN',
          data: PusherData(
            format: _pushFormat,
            url: url,
            additionalProperties: appId == appIdIOS
                ? {
                    'default_payload': {
                      'aps': {
                        'alert': {
                          'title': '畅聊 ChatFlow',
                          'body': '您有一条新消息',
                        },
                        if (audible!) 'sound': 'default',
                      },
                    },
                  }
                : metadata ?? const {},
          ),
        );
        if (identity == _registeredIdentity) {
          if (!_forceRemoteCheck && isRemoteVerified) return true;
          final matches = await _readMatches(desired);
          if (generation != _generation || binding.owner != _owner) {
            return false;
          }
          if (matches) {
            _verified();
            return true;
          }
        }
        _remoteKnown = false;
        await gateway.create(desired);
        if (generation != _generation) {
          // 注册完成时会话已注销/切换：服务端已存在该 pusher → 立即补偿
          // 删除，不把旧账号推送绑定留下来。
          try {
            await gateway.delete(PusherId(appId: appId, pushkey: token));
          } catch (_) {}
          return false;
        }
        if (binding.owner != _owner) return false;
        _registeredToken = token;
        _registeredIdentity = identity;
        _lastSuccessAt = now();
        final matches = await _readMatches(desired);
        if (generation != _generation || binding.owner != _owner) return false;
        if (!matches) throw StateError('pusher readback mismatch');
        _verified();
        diagnostics.record(NotificationDiagStage.push,
            'pusher registered (format=$_pushFormat)');
        return true;
      });
    } catch (error) {
      if (generation != _generation || _binding?.owner != _owner) return false;
      _remoteKnown = false;
      _lastFailureKind = error.runtimeType.toString();
      _lastFailureAt = now();
      diagnostics.record(
          NotificationDiagStage.push, 'register failed: ${error.runtimeType}');
      final retryAfter =
          error is MatrixException && error.errcode == 'M_LIMIT_EXCEEDED'
              ? error.retryAfterMs
              : null;
      _scheduleRetry(
          minimumDelay: retryAfter != null && retryAfter > 0
              ? Duration(milliseconds: retryAfter)
              : null);
      return false;
    }
  }

  Future<bool> _readMatches(Pusher desired) async {
    _forceRemoteCheck = false;
    _checkingRemote = true;
    try {
      final entries = await gateway.list().timeout(const Duration(seconds: 10));
      return entries.any((entry) =>
          entry.appId == desired.appId &&
          entry.pushkey == desired.pushkey &&
          entry.kind == desired.kind &&
          _sameJson(entry.data.toJson(), desired.data.toJson()));
    } finally {
      _checkingRemote = false;
    }
  }

  void _verified() {
    _remoteKnown = true;
    _lastRemoteVerifiedAt = now();
    _lastFailureKind = '';
    _cancelRetry();
  }

  static bool _sameJson(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every((key) =>
              right.containsKey(key) && _sameJson(left[key], right[key]));
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          List.generate(left.length, (i) => i)
              .every((i) => _sameJson(left[i], right[i]));
    }
    return left == right;
  }

  void _scheduleRetry({Duration? minimumDelay}) {
    _retryTimer?.cancel();
    final index = _retryCount < _retryDelays.length
        ? _retryCount++
        : _retryDelays.length - 1;
    var delay = _retryDelays[index];
    if (minimumDelay != null && minimumDelay > delay) delay = minimumDelay;
    _nextRetryAt = now().add(delay);
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
    _nextRetryAt = null;
  }

  /// 外部触发重检查（resume/网络恢复/登录恢复）：不重置退避计数，
  /// 但立即尝试一次；若已在注册中则跳过。
  Future<void> recheck() async {
    if (_nextRetryAt != null && now().isBefore(_nextRetryAt!)) return;
    if (!_checkingRemote) _forceRemoteCheck = true;
    await ensureRegistered();
  }

  /// Token 轮换监听：FCM 刷新 token 后自动重注册。
  Future<void> watchTokenRefresh() async {
    if (_disposed || _unregistering) return;
    _verificationTimer ??= Timer.periodic(verificationInterval, (_) {
      unawaited(recheck());
    });
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
    _remoteKnown = false;
    _verificationTimer?.cancel();
    _verificationTimer = null;
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
        final binding = _lease(token);
        await binding.write(() async {
          // A replacement's create supersedes this account's append=false
          // binding. An old logout must not delete that new same-account write.
          if (binding.owner > _owner) return;
          await gateway.delete(PusherId(appId: appId, pushkey: token));
          diagnostics.record(NotificationDiagStage.push, 'pusher deleted');
        });
      } catch (error) {
        diagnostics.record(
            NotificationDiagStage.push, 'delete failed: ${error.runtimeType}');
      }
      _registeredToken = null;
      _registeredIdentity = null;
    } finally {
      _unregistering = false;
      _binding?.release();
      _binding = null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _remoteKnown = false;
    _verificationTimer?.cancel();
    _verificationTimer = null;
    _cancelRetry();
    await _tokenSub?.cancel();
    _tokenSub = null;
    final pending = _registrationInFlight;
    if (pending != null) await pending;
    if (!_unregistering) {
      _binding?.release();
      _binding = null;
    }
  }
}
