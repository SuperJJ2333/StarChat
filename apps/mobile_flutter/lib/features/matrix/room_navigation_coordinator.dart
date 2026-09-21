import 'package:clock/clock.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../contacts/contact_models.dart';

/// 会话打开入口的来源。
///
/// 用途有两个，且只有两个：
/// 1. **诊断**：把"谁发起这次打开"写进日志/诊断，不改变导航语义；
/// 2. **默认网络策略**：每个入口声明自己的网络姿态（见 [defaultMode]），
///    由 `RoomOpeningPolicy` 读取，入口自身不再各自写 `waitForRoom`。
///
/// 新增入口必须显式声明来源；未声明时回落到 [RoomOpenSource.unknown]
/// （最保守的 [RoomOpenMode.localThenNetwork]）。
enum RoomOpenSource {
  /// 消息列表点击会话（本地已知的既有会话）。
  conversationList('conversation_list', RoomOpenMode.offlineFirst),

  /// 本机历史搜索命中（群聊 / 聊天记录，含 anchor 定位）。
  search('search', RoomOpenMode.offlineFirst),

  /// 好友资料 / 群成员资料「发消息」（已有好友，可能已有 DM）。
  contactProfile('contact_profile', RoomOpenMode.offlineFirst),

  /// 通讯录 → 群聊通讯录列表。
  groupAddressList('group_address_list', RoomOpenMode.offlineFirst),

  /// 建群成功后进入新群（房间已由创建流程加入）。
  groupCreated('group_created', RoomOpenMode.offlineFirst),

  /// 系统通知 / 推送 / 应用内横幅点击（冷启动时房间可能尚未进入本地库）。
  notification('notification', RoomOpenMode.localThenNetwork),

  /// 好友通过后进入会话（私聊已建立，房间刚加入）。
  friendAccept('friend_accept', RoomOpenMode.localThenNetwork),

  /// 扫码入群后进入群聊（入群本身已完成，仍需网络确认成员资格）。
  scan('scan', RoomOpenMode.requireNetwork),

  /// 未声明来源（兜底，禁止新增此来源的生产调用）。
  unknown('unknown', RoomOpenMode.localThenNetwork);

  const RoomOpenSource(this.wireName, this.defaultMode);

  /// 诊断用稳定标识（不含任何用户内容）。
  final String wireName;

  /// 该来源的默认网络姿态。
  final RoomOpenMode defaultMode;
}

/// 打开会话的网络姿态策略。
///
/// 三者都遵守同一条铁律：**本地已加入的房间绝不等待网络**。
/// 差别只在"本地没有这个房间"时的行为。
enum RoomOpenMode {
  /// 离线优先：本地命中立即打开（零网络等待）；本地缺失才允许有界网络回退。
  /// 用于"用户已经能在本地列表里看到它"的入口（消息列表、搜索、好友资料）。
  offlineFirst,

  /// 本地优先、缺失即等待：本地命中立即打开；本地缺失时做有界等待
  /// （通知冷启动、好友通过等"房间可能还没同步进来"的场景）。
  localThenNetwork,

  /// 需要网络：这类入口的前置步骤（入群）本身已经完成，房间若不在本地
  /// 说明前提不成立——不做静默等待，直接给出可见失败。
  requireNetwork,
}

/// 一次「打开房间页面」请求所需的展示数据。
///
/// 只承载 roomId 与展示信息：**不放** Matrix SDK 对象、RoomLease 或
/// BuildContext。租约、路由与页面生命周期由 [RoomNavigationCoordinator]
/// 与 AppHome（composition root）持有；**打开前的策略判定**由
/// `RoomOpeningPolicy` 持有（来源 + 网络姿态 + 失败分类）。
final class RoomOpenRequest {
  const RoomOpenRequest({
    required this.roomId,
    required this.roomName,
    this.initialContact,
    this.anchorEventId,
    this.source = RoomOpenSource.unknown,
    this.modeOverride,
    this.onRoomReady,
    this.onRoomClosed,
    this.outbox = const <String>[],
    this.readOnly = false,
    this.anchorRoomId,
    this.outboxLocalIds = const <String>[],
  });

  /// 页面与租约的唯一键：群聊与私聊都用 Matrix roomId，绝不用名称/用户 ID。
  final String roomId;

  /// 导航栏展示名；为空时由打开流程向会话目录取（roomDisplayName）。
  final String roomName;
  final ContactDetails? initialContact;

  /// 正式的房间导航 anchor 契约（全局搜索/深链）：进入房间后定位并高亮
  /// 该事件。绝不通过全局变量或 SharedPreferences 传递。
  final String? anchorEventId;
  final String? anchorRoomId;
  final List<String> outboxLocalIds;

  /// 本次打开的来源（诊断 + 默认网络策略）。见 [RoomOpenSource]。
  final RoomOpenSource source;

  /// 覆盖来源默认网络姿态（仅当某个入口确有例外时使用；默认 null 表示
  /// 采用 `source.defaultMode`）。
  final RoomOpenMode? modeOverride;

  /// 实际生效的网络姿态。
  RoomOpenMode get mode => modeOverride ?? source.defaultMode;

  /// 租约已取、RoomPage 尚未 push 时回调。消息列表在此补完「进入房间」的
  /// 已读/未读收尾（等待动画与身份预热已在调用方完成）。
  final void Function()? onRoomReady;

  /// RoomPage 退出（push 完成）或打开失败后回调一次；未走到 push 的失败
  /// （例如取租约失败）不会回调，因为调用方此时还没有需要收尾的房间态。
  final void Function()? onRoomClosed;

  /// Offline First：pending conversation 期间排队、进入房间后要自动发送的
  /// 文本（按输入顺序）。只承载数据，不含 SDK 对象。
  final List<String> outbox;

  /// 只读打开（缺陷 0919 项 3）：历史孤儿房间经搜索/通知定位时只允许
  /// 查看历史（保留 roomId+anchor 定位），不提供输入框，不得作为独立
  /// 可发送的会话出现。
  final bool readOnly;
}

/// All entrances open the logical representative; an anchor retains its source
/// room so that historical events can be located in the combined timeline.
RoomOpenRequest normalizeDuplicateRoomOpen(
  RoomOpenRequest request, {
  String? Function(String roomId)? primaryRoomIdOf,
  bool? Function(String roomId)? isDuplicateRoom,
}) {
  final primary = primaryRoomIdOf?.call(request.roomId);
  if (primary == null || primary.isEmpty || primary == request.roomId) {
    return request;
  }
  return RoomOpenRequest(
    roomId: primary,
    roomName: request.roomName,
    initialContact: request.initialContact,
    anchorEventId: request.anchorEventId,
    anchorRoomId: request.anchorRoomId ?? request.roomId,
    source: request.source,
    modeOverride: request.modeOverride,
    onRoomReady: request.onRoomReady,
    onRoomClosed: request.onRoomClosed,
    outbox: request.outbox,
    outboxLocalIds: request.outboxLocalIds,
    readOnly: request.readOnly,
  );
}

/// 打开流程与协调器之间的路由登记句柄。
///
/// 打开流程必须在 `Navigator.push` 之前调用 [register]，在页面退出/失败时
/// 调用 [release]；协调器据此实现「同一 roomId 只有一个活动 RoomPage」。
final class RoomRouteHandle {
  RoomRouteHandle._(
      this._coordinator, this.roomId, this.physicalRoomId, this.replacedRoute);

  final RoomNavigationCoordinator _coordinator;
  final String roomId;
  final String physicalRoomId;
  final Route<void>? replacedRoute;

  /// 当前已登记的活动路由（未登记或已释放为 null）。
  Route<void>? get route => _coordinator._active[roomId];

  /// 登记活动路由（push 之前调用）。
  ///
  /// 路由一旦建立就同时结束「正在打开」状态：此后同房间请求走
  /// 「已打开 → 回到原页面」，也避免页面退出后租约取消期间把新的打开
  /// 请求并进一个已经不再开新页面的 opening future。
  void register(Route<void> route, {void Function(RoomOpenRequest)? onReopen}) {
    if (onReopen != null) _coordinator._reopen[roomId] = onReopen;
    _coordinator._active[roomId] = route;
    _coordinator._physicalRooms[roomId] = physicalRoomId;
    _coordinator._opening.remove(roomId);
    final latest = _coordinator._openingAnchors.remove(roomId);
    if (latest != null) onReopen?.call(latest);
  }

  /// 释放登记：只释放自己登记的那条路由，避免误删后来者。
  void release(Route<void> route) {
    if (identical(_coordinator._active[roomId], route)) {
      _coordinator._active.remove(roomId);
      _coordinator._reopen.remove(roomId);
      _coordinator._physicalRooms.remove(roomId);
    }
  }

  bool get hasActiveRoute => route?.isActive ?? false;
}

/// 真正的打开流程（AppHome 提供）：取租约 → 构建 RoomPage → [RoomRouteHandle]
/// 登记路由 → 绑定 revoke → push → 页面退出后释放租约。
typedef RoomOpenProcedure = Future<void> Function(
    RoomOpenRequest request, RoomRouteHandle handle);

/// 房间导航协调器：以 **roomId** 为唯一键保证「同一房间只有一个活动 RoomPage」。
///
/// - **正在打开**：同 roomId 的后续请求复用同一个 opening future，不重复取租约、
///   不重复 push；
/// - **已打开**：不 push 新页面，`popUntil` 回到既有 RoomPage（Room A → 好友资料
///   → 发消息 → 回到原 Room A，而不是叠加第二层）；
/// - **打开失败 / 页面退出**：清理 opening 与 active 登记，绝不留假 active；
/// - **账号切换 / AppHome dispose**：[dispose]/[clear] 清空全部登记，旧账号的
///   房间路由不得泄漏给下一个账号。
///
/// 与 `DirectMessageOpenGate` 的分工：后者按好友入口去重（peer 级），本协调器
/// 按房间页面去重（roomId 级），两者并存、互不替代。
final class RoomNavigationCoordinator {
  RoomNavigationCoordinator({
    required RoomOpenProcedure openRoom,
    required NavigatorState? Function() navigatorOf,
    String Function(String roomId)? conversationKeyOf,
    Duration stuckOpenTimeout = const Duration(seconds: 15),
  })  : _openRoom = openRoom,
        _navigatorOf = navigatorOf,
        _conversationKeyOf = conversationKeyOf ?? ((id) => id),
        _stuckOpenTimeout = stuckOpenTimeout;

  /// 卡死兜底（E1）：一次打开流程若超过该时长仍未结束（低端机上任何
  /// await 挂起都会导致该房间在本次会话内永远点不开），后续点击将
  /// 丢弃旧入口并自动重启完整流程。
  final Duration _stuckOpenTimeout;

  final RoomOpenProcedure _openRoom;
  final String Function(String roomId) _conversationKeyOf;
  final NavigatorState? Function() _navigatorOf;
  final Map<String, Future<void>> _opening = {};
  final Map<String, DateTime> _openingSince = {};
  final Map<String, RoomOpenRequest> _openingAnchors = {};
  final Map<String, Route<void>> _active = {};
  final Map<String, String> _physicalRooms = {};
  bool _disposed = false;
  int _generation = 0;

  @visibleForTesting
  bool isOpening(String roomId) =>
      _opening.containsKey(_conversationKeyOf(roomId.trim()));

  Route<void>? activeRoute(String roomId) =>
      _active[_conversationKeyOf(roomId.trim())];

  @visibleForTesting
  int get openingCount => _opening.length;

  @visibleForTesting
  List<String> get activeRoomIds => List.unmodifiable(_active.keys);

  /// 打开（或回到）某个房间。返回值在页面退出、打开失败或复用既有请求时完成。
  final _reopen = <String, void Function(RoomOpenRequest)>{};

  Future<void> open(RoomOpenRequest request) {
    if (request.roomId.trim().isEmpty || _disposed) return Future<void>.value();
    final roomId = _conversationKeyOf(request.roomId.trim());
    if (roomId.isEmpty || _disposed) return Future<void>.value();

    // 已打开优先于正在打开：打开流程会一直持有到页面关闭，因此「正在打开」
    // 不能覆盖「已打开」，否则再次请求会并进旧的 future 而不是回到原页面。
    final active = _active[roomId];
    if (active != null &&
        active.isActive &&
        _physicalRooms[roomId] == request.roomId) {
      _reopen[roomId]?.call(request);
      // 情况 2：房间已打开——回到原页面，绝不 push 第二层。
      _navigatorOf()?.popUntil((candidate) => identical(candidate, active));
      return Future<void>.value();
    }
    if (active != null) _active.remove(roomId); // 失效登记兜底

    final opening = _opening[roomId];
    if (opening != null) {
      // E1 卡死兜底（惰性判定，无定时器）：挂起超过 [_stuckOpenTimeout]
      // 且该房间仍未注册路由 → 判定旧流程已死，丢弃入口改走完整新流程。
      final since = _openingSince[roomId];
      final stuck = since != null &&
          clock.now().difference(since) >= _stuckOpenTimeout &&
          _active[roomId]?.isActive != true;
      if (!stuck) {
        if (request.anchorEventId?.isNotEmpty == true) {
          _openingAnchors[roomId] = request;
        }
        return opening;
      }
      debugPrint(
          '[room-nav] STUCK cleared room=$roomId age='
          '${clock.now().difference(since).inMilliseconds}ms');
      _opening.remove(roomId);
      _openingAnchors.remove(roomId);
      _openingSince.remove(roomId);
    }

    // 先登记 opening 再启动流程：打开流程在第一个 await 之前会同步执行
    // 「取租约前」的一段（甚至直接 register 路由），必须先占位才能被合并。
    final completer = Completer<void>();
    final pending = completer.future;
    _opening[roomId] = pending;
    _openingSince[roomId] = clock.now();
    unawaited(_run(roomId, request, active?.isActive == true ? active : null)
        .then((_) {
      if (identical(_opening[roomId], pending)) {
        _opening.remove(roomId);
        _openingAnchors.remove(roomId);
        _openingSince.remove(roomId);
      }
      if (!completer.isCompleted) completer.complete();
    }, onError: (Object error, StackTrace stackTrace) {
      if (identical(_opening[roomId], pending)) {
        _opening.remove(roomId);
        _openingAnchors.remove(roomId);
        _openingSince.remove(roomId);
      }
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }));
    return pending;
  }

  Future<void> _run(String roomId, RoomOpenRequest request,
      Route<void>? replacedRoute) async {
    final generation = _generation;
    final previousPhysicalRoom = _physicalRooms[roomId];
    final previousReopen = _reopen[roomId];
    final handle =
        RoomRouteHandle._(this, roomId, request.roomId, replacedRoute);
    try {
      await _openRoom(request, handle);
    } catch (_) {
      // 打开失败不得留下假 active；opening 由 open() 的 whenComplete 清理。
      final route = _active[roomId];
      if (route == null || !route.isActive) {
        _active.remove(roomId);
        _physicalRooms.remove(roomId);
        _reopen.remove(roomId);
        // The old page stays usable until replacement is actually pushed.
        // Restore all route identity after acquisition/push failure, but never
        // resurrect a prior account's route after clear/dispose.
        if (!_disposed &&
            generation == _generation &&
            replacedRoute?.isActive == true) {
          _active[roomId] = replacedRoute!;
          if (previousPhysicalRoom != null) {
            _physicalRooms[roomId] = previousPhysicalRoom;
          }
          if (previousReopen != null) _reopen[roomId] = previousReopen;
        }
      }
      rethrow;
    }
  }

  /// 账号切换/退出登录：清空登记，旧账号的房间路由请求不得泄漏到下一个账号。
  void clear() {
    _generation++;
    _opening.clear();
    _openingAnchors.clear();
    _openingSince.clear();
    _active.clear();
    _physicalRooms.clear();
    _reopen.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}
