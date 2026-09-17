import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/matrix/screen_capture_protection.dart';

/// 闪照（阅后即焚图片）：
/// - 气泡缩略图 = 低分辨率解码 + 最近邻放大的马赛克，中央闪电角标；
/// - 未销毁时点击进入查看页：马赛克 + 「长按屏幕可查看 3 秒」；
/// - 长按显示原图（带轻量动态水印），右上角 3 秒圆圈倒计时；松手或超时
///   立即销毁且不可重新查看；
/// - 查看期间申请安全窗口租约（Android FLAG_SECURE）；iOS 录屏/镜像或
///   系统截图（截图是**事后**通知）会立即隐藏原图并销毁；
/// - 销毁后气泡叠加「闪照已销毁」，不可再次打开，也不可转发。
///
/// 原图仅通过端到端加密事件传输；本组件不提供保存/转发入口。
/// 明确边界：无法阻止另一台设备拍摄屏幕、root/越狱或系统级 hook。

/// 阅后即焚标记（按账号 + 房间 + 事件 ID 持久化）。
///
/// **安全不变量**：标记一经写入**绝不因容量原因淘汰**。闪照一旦在本设备销毁，
/// 只要该消息事件仍存在于本地，就永远不能再被 reveal。旧实现有
/// `_maxEntries = 500` 的“最早一条淘汰”，超过 500 条后最早那批已销毁的闪照会
/// 重新变成「未查看」并可被再次打开——这对阅后即焚是不可接受的 fail-open。
///
/// 存储治理只跟随**真实生命周期**（不是计数）：
/// - [dropForEventIds]：单条消息在本地被**永久删除**时，按事件 ID 移除；
/// - [clearRoom]：某房间的本地历史被**永久**清除时，只移除该房间的标记；
/// - [clear] / [clearAccount]：该账号本地加密库被整体删除时清空。
///
/// **反向不变量**（同样必须遵守）：以下情况**不得**清理标记，否则旧事件重新
/// 同步后会重新变成「未查看」并可再次打开（fail-open）：
/// - 软隐藏 / 撤回展示 / `clearLocalHistory` 的 cutoff 语义（事件仍在本地库）；
/// - 普通登出（[MatrixTokenLoginGateway.suspend] 明确保留加密库与本地历史）。
final class FlashPhotoViewedStore {
  FlashPhotoViewedStore._(this._prefs, this._key);

  static const _prefix = 'flash-viewed';

  /// 房间维度与事件 ID 的分隔符（U+0000 不会出现在 Matrix roomId/eventId 中）。
  static const _roomSeparator = '\u0000';

  final SharedPreferences _prefs;
  final String _key;
  final Set<String> _viewed = <String>{};
  final _listeners = <VoidCallback>{};

  /// 持久化 key（`flash-viewed:<accountKey>`），登出清理路径复用。
  static String keyFor(String accountKey) => '$_prefix:$accountKey';

  static Future<FlashPhotoViewedStore> load(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    final key = keyFor(accountKey);
    final store = FlashPhotoViewedStore._(prefs, key);
    store._viewed.addAll(prefs.getStringList(key) ?? const <String>[]);
    return store;
  }

  /// 账号登出/账号数据重置：不必先加载实例即可清空该账号的全部标记。
  static Future<void> clearAccount(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyFor(accountKey));
  }

  /// 是否已销毁。
  ///
  /// 同时匹配「房间维度」与「旧格式（仅 eventId）」两种条目，因此升级前写入
  /// 的标记不会因为格式变化而失效（那会造成历史闪照复活）。
  bool isViewed(String eventId) {
    if (_viewed.contains(eventId)) return true;
    final suffix = '$_roomSeparator$eventId';
    for (final entry in _viewed) {
      if (entry.endsWith(suffix)) return true;
    }
    return false;
  }

  /// 已记录标记数（仅测试观察，用于证明不存在容量淘汰）。
  @visibleForTesting
  int get debugCount => _viewed.length;

  /// 记录已销毁。
  ///
  /// 传入 [roomId] 时会连同房间维度一起存储，使「某房间本地历史被永久清除」
  /// 可以只清理该房间（[clearRoom]）而不误删其他房间。
  void markViewed(String eventId, {String? roomId}) {
    final key = roomId == null || roomId.isEmpty
        ? eventId
        : '$roomId$_roomSeparator$eventId';
    if (!_viewed.add(key)) return;
    _persist();
  }

  /// 真实生命周期清理：单条消息在本地被**永久删除**时调用。
  ///
  /// **不得**用于容量控制（那正是本 store 被移除的 fail-open 行为），也不得
  /// 用于软隐藏/撤回（事件仍会重新同步）。
  void dropForEventIds(Iterable<String> eventIds) {
    var changed = false;
    for (final eventId in eventIds) {
      final suffix = '$_roomSeparator$eventId';
      final toRemove = _viewed
          .where((entry) => entry == eventId || entry.endsWith(suffix))
          .toList(growable: false);
      for (final entry in toRemove) {
        if (_viewed.remove(entry)) changed = true;
      }
    }
    if (changed) _persist();
  }

  /// 真实生命周期清理：某房间的本地历史被**永久**清除时调用。
  ///
  /// 只移除该房间的标记；**其他房间不受影响**。软隐藏（cutoff）语义下不得
  /// 调用——事件仍在本地库，会重新同步。
  Future<void> clearRoom(String roomId) async {
    if (roomId.isEmpty) return;
    final prefix = '$roomId$_roomSeparator';
    final toRemove =
        _viewed.where((entry) => entry.startsWith(prefix)).toList(growable: false);
    if (toRemove.isEmpty) return;
    for (final entry in toRemove) {
      _viewed.remove(entry);
    }
    _persist();
  }

  /// 账号登出/重置：清空本账号全部标记（持久层一并移除）。
  Future<void> clear() async {
    if (_viewed.isNotEmpty) _viewed.clear();
    await _prefs.remove(_key);
    _notify();
  }

  void _persist() {
    _prefs.setStringList(_key, _viewed.toList(growable: false));
    _notify();
  }

  void _notify() {
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
  }

  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

/// 马赛克渲染：极低分辨率解码（默认 26px 宽）+ 最近邻放大成块状像素。
final class FlashMosaicImage extends StatelessWidget {
  const FlashMosaicImage(
      {super.key, required this.bytes, this.mosaicWidth = 26});

  final Uint8List bytes;
  final int mosaicWidth;

  @override
  Widget build(BuildContext context) => Image(
        key: const Key('flash-mosaic-image'),
        image: ResizeImage(MemoryImage(bytes),
            width: mosaicWidth, policy: ResizeImagePolicy.exact),
        filterQuality: FilterQuality.none,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          color: const Color(0xFF3A3A3C),
          alignment: Alignment.center,
          child: const Icon(CupertinoIcons.bolt_fill,
              size: 36, color: CupertinoColors.systemYellow),
        ),
      );
}

/// 闪电角标：马赛克中央的黄色闪电圆片。
final class FlashBoltBadge extends StatelessWidget {
  const FlashBoltBadge({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('flash-bolt-badge'),
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xCC1B1B1D),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(CupertinoIcons.bolt_fill,
            size: size * .55, color: CupertinoColors.systemYellow),
      );
}

/// 聊天气泡中的闪照缩略（不响应点击；打开逻辑由外层根据销毁态决定）。
final class FlashPhotoBubble extends StatefulWidget {
  const FlashPhotoBubble({
    super.key,
    required this.loadOriginal,
    required this.viewed,
    this.width = 180,
    this.height = 220,
  });

  /// 解密加载原图字节（调用方负责内存缓存；闪照不走磁盘预览缓存）。
  final Future<Uint8List> Function() loadOriginal;
  final bool viewed;
  final double width;
  final double height;

  @override
  State<FlashPhotoBubble> createState() => _FlashPhotoBubbleState();
}

final class _FlashPhotoBubbleState extends State<FlashPhotoBubble> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.loadOriginal();
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _error = '闪照加载失败');
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const Key('flash-photo-bubble'),
        width: widget.width,
        height: widget.height,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF2C2C2E),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(fit: StackFit.expand, children: [
            if (_bytes != null)
              FlashMosaicImage(bytes: _bytes!)
            else if (_error != null)
              Center(
                  child: Text(_error!,
                      style: const TextStyle(
                          fontSize: 12, color: CupertinoColors.systemGrey)))
            else
              const Center(child: CupertinoActivityIndicator(radius: 9)),
            const Center(child: FlashBoltBadge()),
            if (widget.viewed)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: const Color(0xB31B1B1D),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  alignment: Alignment.center,
                  child: const Text('闪照已销毁',
                      key: Key('flash-destroyed-caption'),
                      style: TextStyle(
                          fontSize: 11, color: CupertinoColors.systemGrey5)),
                ),
              ),
          ]),
        ),
      );
}

/// 3 秒圆圈倒计时（闪电 + 环形进度）。
final class FlashCountdownRing extends StatelessWidget {
  const FlashCountdownRing({super.key, required this.remaining, this.total});

  final Duration remaining;
  final Duration? total;

  @override
  Widget build(BuildContext context) {
    final span = (total ?? FlashPhotoViewerPage.viewDuration).inMilliseconds;
    final progress = span <= 0 ? 0.0 : remaining.inMilliseconds / span;
    return SizedBox(
      key: const Key('flash-countdown-ring'),
      width: 44,
      height: 44,
      child: CustomPaint(
        painter: _RingPainter(progress.clamp(0.0, 1.0)),
        child: const Center(
          child: Icon(CupertinoIcons.bolt_fill,
              size: 18, color: CupertinoColors.systemYellow),
        ),
      ),
    );
  }
}

final class _RingPainter extends CustomPainter {
  const _RingPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final deflated = rect.deflate(3);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0x66FFFFFF);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..color = const Color(0xFFFFCC00);
    canvas.drawArc(deflated, -1.5708, 6.2832, false, track);
    canvas.drawArc(deflated, -1.5708, 6.2832 * progress, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

/// 原图 reveal 时的轻量动态水印（威慑用，不是主要安全机制）。
/// 不含手机号/邮箱/token/Matrix ID/内部 userId。
final class FlashWatermark extends StatelessWidget {
  const FlashWatermark({super.key, this.phase = 0});

  /// 位置相位（0..2）：轻微移动，避免固定叠在脸部中央。
  final int phase;

  @override
  Widget build(BuildContext context) {
    final alignment = switch (phase % 3) {
      0 => Alignment.topLeft,
      1 => Alignment.centerRight,
      _ => Alignment.bottomCenter,
    };
    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Transform.rotate(
            angle: -0.35,
            child: Text(
              '闪照 · 仅限当前查看',
              key: const Key('flash-watermark'),
              style: TextStyle(
                fontSize: 13,
                color: CupertinoColors.white.withValues(alpha: 0.28),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 查看器内部状态的只读观察面（供测试断言；不暴露字节内容）。
abstract interface class FlashViewerDebugState {
  /// 是否仍持有原图字节引用——销毁之后必须为 `false`。
  bool get debugHasOriginalBytes;
  bool get debugRevealed;
  bool get debugDestroyed;

  /// 异步代际计数：destroy/dispose 递增，过期结果必须被丢弃。
  int get debugGeneration;

  /// 销毁次数与首次销毁原因（证明“唯一销毁路径 + 恰好一次”）。
  int get debugDestroyCount;
  String? get debugDestroyReason;
}

/// 显式安全事件入口：宿主/安全模块可主动要求销毁当前闪照。
///
/// 与截图、录屏/镜像等信号**完全等价**：走同一条唯一销毁路径，不会二次回调。
abstract interface class FlashViewerSecuritySink {
  void reportSecurityEvent();
}

/// 闪照查看页：马赛克 → 长按 3 秒原图（带水印）→ 销毁。
///
/// 安全行为：
/// - 进入即申请安全窗口租约（Android FLAG_SECURE 在用户长按之前就已开启）；
///   申请是异步的，因此 reveal 还要求 [ScreenCaptureProtection.readiness]
///   为 `ready`——就绪之前长按无效（不会出现“先显示、后开启安全窗口”的空窗）；
/// - iOS 录屏/镜像进行中：禁止 reveal，长按无效并提示；
/// - 捕获状态 `unknown`（快照调用失败且未收到事件）同样 fail closed；
/// - 所有销毁入口（倒计时到期、提前松手、长按取消、截图、开始录屏/镜像、
///   退到后台、显式安全事件、原图加载失败）统一走 [_destroyFlash]，它必须
///   释放原图字节引用（见 [FlashPhotoViewerPageState.debugHasOriginalBytes]）。
///
/// **退出也必须收口**（本页最容易被绕过的 fail-open 点）：
/// 只要原图**真正进入过 reveal 状态**（[_hasEverRevealed]），那么之后任何
/// 退出路径——3 秒超时、松手、长按取消、截图、录屏、退到后台、系统返回、
/// `Navigator.pop`、`removeRoute`、route replacement、widget `dispose`——
/// 都必须收敛为「已销毁」并持久化 tombstone。
/// [dispose] 是**最后一道保险**：它不能 `setState`，因此把「UI 状态收敛」
/// 与「持久化销毁回调」拆开（[_markDestroyed] + 一次 [FlashPhotoViewerPage.onDestroyed]）。
///
/// 反向不变量：**从未 reveal** 的查看器退出时**不得**标记已查看——普通关闭
/// （点 X / 系统返回）不消耗查看机会。
final class FlashPhotoViewerPage extends StatefulWidget {
  const FlashPhotoViewerPage(
      {super.key,
      required this.loadOriginal,
      this.onDestroyed,
      this.protection});

  static const viewDuration = Duration(seconds: 3);

  final Future<Uint8List> Function() loadOriginal;
  final VoidCallback? onDestroyed;

  /// 屏幕捕获保护服务（默认生产单例；测试注入假实现）。
  final ScreenCaptureProtection? protection;

  @override
  FlashPhotoViewerPageState createState() => FlashPhotoViewerPageState();
}

final class FlashPhotoViewerPageState extends State<FlashPhotoViewerPage>
    with WidgetsBindingObserver
    implements FlashViewerDebugState, FlashViewerSecuritySink {
  Uint8List? _bytes;
  bool _revealed = false;
  bool _destroyed = false;
  Duration _remaining = FlashPhotoViewerPage.viewDuration;
  Timer? _countdown;
  ScreenCaptureLease? _lease;
  StreamSubscription<void>? _screenshotSubscription;
  int _watermarkPhase = 0;

  /// 本次查看器是否**真正显示过原图**（至少一帧）。
  ///
  /// 这是安全契约的判定基准：不能只看 `_revealed`——退出路径上 `_revealed`
  /// 可能已经被清掉，但用户其实已经看到了原图，此时退出仍必须按「已查看」
  /// 处理。反之，从未 reveal 就关闭**不消耗**查看机会。
  bool _hasEverRevealed = false;

  /// `widget.onDestroyed` 是否已经派发（**恰好一次**的守卫）。
  bool _destroyNotificationSent = false;

  /// 异步代际：destroy/dispose 时递增。在途的 `loadOriginal()` / 租约申请
  /// 返回后若代际已变（或已卸载/已销毁），结果**立即丢弃**，绝不 setState。
  int _generation = 0;
  int _destroyCount = 0;
  String? _destroyReason;

  ScreenCaptureProtection get _protection =>
      widget.protection ?? ScreenCaptureProtection.instance;

  ScreenProtectionReadiness get _protectionReadiness =>
      _protection.readiness.value;
  ScreenCaptureState get _captureState => _protection.captureState.value;

  /// reveal 的**唯一**前置条件：安全窗口 `ready` + 捕获状态**已知**且未在
  /// 录屏/镜像 + 未销毁 + 原图已就绪。`initializing`/`failed`/`unknown`
  /// 一律 fail closed。
  bool get _canReveal =>
      !_destroyed &&
      _bytes != null &&
      _protectionReadiness == ScreenProtectionReadiness.ready &&
      _captureState == ScreenCaptureState.inactive;

  @override
  @visibleForTesting
  bool get debugHasOriginalBytes => _bytes != null;

  @override
  @visibleForTesting
  bool get debugRevealed => _revealed;

  @override
  @visibleForTesting
  bool get debugDestroyed => _destroyed;

  @override
  @visibleForTesting
  int get debugGeneration => _generation;

  @override
  @visibleForTesting
  int get debugDestroyCount => _destroyCount;

  @override
  @visibleForTesting
  String? get debugDestroyReason => _destroyReason;

  /// 显式安全事件（宿主/安全模块上报）：与截图/录屏信号等价，
  /// 走唯一销毁路径，最多触发一次 `onDestroyed`。
  @override
  void reportSecurityEvent() => _destroyFlash(reason: 'security-event');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 必须在任何 reveal 之前就把安全窗口打开（不等长按）。readiness 未
    // `ready` 之前 _canReveal 为 false，长按不会 reveal。
    unawaited(_acquireLease());
    _protection.readiness.addListener(_protectionChanged);
    _protection.captureState.addListener(_protectionChanged);
    _screenshotSubscription = _protection.screenshots.listen((_) {
      // iOS：userDidTakeScreenshot 在截屏完成之后到达——事后销毁。
      _destroyFlash(reason: 'screenshot');
    });
    unawaited(_load());
  }

  Future<void> _acquireLease() async {
    final generation = _generation;
    // acquire() 自身不抛：平台失败会体现在 readiness == failed（fail closed）。
    final lease = await _protection.acquire();
    // 过期/已销毁的租约立即释放，绝不挂到一个已失效的查看器上。
    if (!mounted || _generation != generation || _destroyed) {
      await lease.release();
      return;
    }
    _lease = lease;
    if (mounted) setState(() {});
  }

  void _protectionChanged() {
    if (!mounted) return;
    // 只有「已经 reveal」才会因为捕获状态变化而销毁：未 reveal 时正在录屏
    // 只是禁止 reveal（长按无效 + 明确提示），录屏结束后仍可正常查看，
    // 不得把闪照误标记为已销毁。
    if (_revealed && !_canReveal) {
      _destroyFlash(
          reason: _captureState == ScreenCaptureState.active
              ? 'capture-active'
              : 'protection-not-ready');
      return;
    }
    // 录屏结束 / 就绪完成：刷新提示与长按可用性（已销毁则不可恢复）。
    setState(() {});
  }

  /// **唯一**销毁路径。所有触发点都必须调用它：
  /// 3 秒倒计时到期、提前松手（`onLongPressEnd`）、`onLongPressCancel`、
  /// 截图信号、开始录屏/镜像、退到后台/失去焦点、显式安全事件、
  /// 原图加载失败（`notify: false`，用户没看到就不算“已查看”），
  /// 以及 [dispose] 的最后保险。
  ///
  /// 保证（由 [_markDestroyed] + 本方法共同实现）：
  /// - 取消倒计时并把 `_countdown` 置空；
  /// - `_revealed = false`、`_destroyed = true`；
  /// - `_bytes = null`（释放原图引用；Dart 不保证物理清零）；
  /// - 递增异步代际（在途结果作废）；
  /// - `widget.onDestroyed` **最多调用一次**（重复触发直接返回）。
  ///
  /// [notify] 为 false 时只做状态收敛，不派发持久化回调（用于「用户从未看到
  /// 原图」的路径：加载失败、以及从未 reveal 的普通退出）。
  void _destroyFlash({required String reason, bool notify = true}) {
    if (_destroyed) return;
    _markDestroyed(reason);
    if (!mounted) {
      // 已经不在树上（dispose 期间）：不能 setState，但持久化仍必须完成。
      // 只有在本次确实 reveal 过时才允许 notify——否则普通退出会误标记。
      if (notify && _hasEverRevealed) _notifyDestroyed();
      return;
    }
    setState(() {});
    if (notify) _notifyDestroyed();
  }

  /// 状态收敛（可在 `dispose` 中安全调用：**不** `setState`、**不** 回调）。
  ///
  /// 幂等：只有真实发生销毁时才递增 [_destroyCount] 并记录首个原因。
  void _markDestroyed(String reason) {
    if (_destroyed) return;
    _countdown?.cancel();
    _countdown = null;
    _generation++;
    _destroyed = true;
    _revealed = false;
    _bytes = null;
    _destroyCount++;
    _destroyReason ??= reason;
  }

  /// 持久化销毁回调，**恰好一次**。
  void _notifyDestroyed() {
    if (_destroyNotificationSent) return;
    _destroyNotificationSent = true;
    widget.onDestroyed?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 安全优先：reveal 状态下切后台/失去焦点立即销毁，回前台不自动恢复。
    if (state != AppLifecycleState.resumed) {
      if (_revealed) _destroyFlash(reason: 'background');
      return;
    }
    // 回前台：Activity/场景重建可能丢过 FLAG_SECURE，重申安全窗口。
    if (_lease != null) unawaited(_protection.reassert());
  }

  Future<void> _load() async {
    final generation = _generation;
    try {
      final bytes = await widget.loadOriginal();
      // 过期结果（代际已变 / 已销毁 / 已卸载）：立即丢弃引用，绝不 setState。
      if (!mounted || _destroyed || _generation != generation) return;
      setState(() => _bytes = bytes);
    } catch (_) {
      if (!mounted || _destroyed || _generation != generation) return;
      _destroyFlash(reason: 'load-error', notify: false);
    }
  }

  void _startReveal() {
    if (_revealed || !_canReveal) return;
    setState(() {
      _revealed = true;
      // 一旦真正进入 reveal 状态，本次查看即**不可撤销**：此后任何退出路径
      // 都会被判定为「已查看」。这一标记必须在首帧原图渲染之前就置位。
      _hasEverRevealed = true;
      _remaining = FlashPhotoViewerPage.viewDuration;
      _watermarkPhase = (_watermarkPhase + 1) % 3;
    });
    _countdown?.cancel();
    var elapsedMs = 0;
    const tick = Duration(milliseconds: 100);
    _countdown = Timer.periodic(tick, (timer) {
      elapsedMs += tick.inMilliseconds;
      if (!mounted || _destroyed || !_revealed) return;
      final remaining =
          FlashPhotoViewerPage.viewDuration - Duration(milliseconds: elapsedMs);
      if (remaining <= Duration.zero) {
        _destroyFlash(reason: 'timeout');
        return;
      }
      setState(() => _remaining = remaining);
    });
  }

  @override
  void dispose() {
    // —— 最后一道安全保险 ——
    // 只要原图真正显示过一帧，退出就是「已查看」：必须收敛到 destroyed 并
    // 持久化 tombstone。这里**不能** setState，因此只做状态收敛 + 一次回调。
    // 从未 reveal 时只收敛状态、不 notify（普通关闭不消耗查看机会）。
    if (_hasEverRevealed && !_destroyed) {
      _markDestroyed('route-exit');
    }
    if (_hasEverRevealed) _notifyDestroyed();
    // 在途 load/lease 结果一律作废，并释放原图引用。
    // 用 [_markDestroyed] 的幂等语义：从未 reveal 的正常关闭**不得**被算成
    // 「销毁一次」（否则会污染销毁计数与原因诊断）。
    if (!_destroyed) {
      _generation++;
      _countdown?.cancel();
      _countdown = null;
      _bytes = null;
      _revealed = false;
      _destroyed = true;
    }
    WidgetsBinding.instance.removeObserver(this);
    _protection.readiness.removeListener(_protectionChanged);
    _protection.captureState.removeListener(_protectionChanged);
    _screenshotSubscription?.cancel();
    _screenshotSubscription = null;
    final lease = _lease;
    _lease = null;
    if (lease != null) unawaited(lease.release());
    super.dispose();
  }

  /// 当前提示文案：不可 reveal 时给出**明确原因**（fail closed 不静默）。
  String get _hintText => flashViewerHintText(
        destroyed: _destroyed,
        captureActive: _captureState == ScreenCaptureState.active,
        protectionUnavailable:
            _protectionReadiness == ScreenProtectionReadiness.failed,
        protectionInitializing:
            _protectionReadiness == ScreenProtectionReadiness.initializing,
        captureUnknown: _captureState == ScreenCaptureState.unknown,
      );

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        key: const Key('flash-photo-viewer'),
        backgroundColor: CupertinoColors.black,
        child: SafeArea(
          child: Stack(children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
                // 保护未就绪 / 捕获状态未知 / 正在录屏 / 已销毁：长按无效。
                onLongPressStart: _canReveal ? (_) => _startReveal() : null,
                onLongPressEnd: (_) {
                  if (_revealed) _destroyFlash(reason: 'release');
                },
                onLongPressCancel: () {
                  if (_revealed) _destroyFlash(reason: 'cancel');
                },
                child: _destroyed
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(CupertinoIcons.bolt_fill,
                                size: 34, color: CupertinoColors.systemGrey),
                            const SizedBox(height: 10),
                            Text(
                              '闪照已销毁',
                              key: const Key('flash-viewer-destroyed'),
                              style: const TextStyle(
                                  fontSize: 14,
                                  color: CupertinoColors.systemGrey5),
                            ),
                          ],
                        ),
                      )
                    : _bytes == null
                        ? const Center(child: CupertinoActivityIndicator())
                        : _revealed
                            ? Stack(fit: StackFit.expand, children: [
                                Center(
                                  child: Image(
                                    key: const Key('flash-revealed-image'),
                                    image: MemoryImage(_bytes!),
                                    filterQuality: FilterQuality.medium,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                                FlashWatermark(phase: _watermarkPhase),
                              ])
                            : Center(
                                child: AspectRatio(
                                  aspectRatio: 3 / 4,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      FlashMosaicImage(bytes: _bytes!),
                                      const Center(
                                          child: FlashBoltBadge(size: 56)),
                                    ],
                                  ),
                                ),
                              ),
              ),
            ),
            Positioned(
              top: 8,
              right: 12,
              child: _revealed
                  ? FlashCountdownRing(remaining: _remaining)
                  : CupertinoButton(
                      key: const Key('flash-viewer-close'),
                      padding: EdgeInsets.zero,
                      onPressed: () => Navigator.pop(context),
                      child: const Icon(CupertinoIcons.xmark,
                          size: 20, color: CupertinoColors.white),
                    ),
            ),
            if (!_revealed && !_destroyed && _bytes != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 48,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0x661B1B1D),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      _hintText,
                      key: Key(_canReveal
                          ? 'flash-hold-hint'
                          : 'flash-capture-blocked'),
                      style: const TextStyle(
                          fontSize: 12, color: CupertinoColors.systemGrey5),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
}

/// 闪照查看页提示文案（可单测）。
///
/// 优先级：已销毁 → 安全保护不可用 → 安全保护启用中 → 正在录屏/镜像 →
/// 捕获状态未知 → 长按提示（3 秒）。
/// [protectionUnavailable]、[protectionInitializing]、[captureUnknown]
/// 都表示「不可 reveal」，必须有明确文案，绝不静默继续显示原图。
String flashViewerHintText({
  required bool destroyed,
  required bool captureActive,
  bool protectionUnavailable = false,
  bool protectionInitializing = false,
  bool captureUnknown = false,
}) {
  if (destroyed) return '闪照已销毁';
  // Android：安全窗口（FLAG_SECURE）无法启用 → 明确告知能力不可用。
  if (protectionUnavailable) return '当前设备无法启用闪照安全保护';
  if (protectionInitializing) return '正在启用闪照安全保护，请稍候';
  if (captureActive) return '正在录屏或共享屏幕，无法查看闪照';
  // unknown ≠ inactive：必须 fail closed。
  if (captureUnknown) return '无法确认屏幕安全状态，暂不可查看';
  return '长按屏幕可查看 ${FlashPhotoViewerPage.viewDuration.inSeconds} 秒';
}
