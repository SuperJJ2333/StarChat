import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../contacts/contact_models.dart';

/// 一次「打开房间页面」请求所需的展示数据。
///
/// 只承载 roomId 与展示信息：**不放** Matrix SDK 对象、RoomLease 或
/// BuildContext。租约、路由与页面生命周期由 [RoomNavigationCoordinator]
/// 与 AppHome（composition root）持有。
final class RoomOpenRequest {
  const RoomOpenRequest({
    required this.roomId,
    required this.roomName,
    this.initialContact,
    this.onRoomReady,
    this.onRoomClosed,
  });

  /// 页面与租约的唯一键：群聊与私聊都用 Matrix roomId，绝不用名称/用户 ID。
  final String roomId;

  /// 导航栏展示名；为空时由打开流程向会话目录取（roomDisplayName）。
  final String roomName;
  final ContactDetails? initialContact;

  /// 租约已取、RoomPage 尚未 push 时回调。消息列表在此补完「进入房间」的
  /// 已读/未读收尾（等待动画与身份预热已在调用方完成）。
  final void Function()? onRoomReady;

  /// RoomPage 退出（push 完成）或打开失败后回调一次；未走到 push 的失败
  /// （例如取租约失败）不会回调，因为调用方此时还没有需要收尾的房间态。
  final void Function()? onRoomClosed;
}

/// 打开流程与协调器之间的路由登记句柄。
///
/// 打开流程必须在 `Navigator.push` 之前调用 [register]，在页面退出/失败时
/// 调用 [release]；协调器据此实现「同一 roomId 只有一个活动 RoomPage」。
final class RoomRouteHandle {
  RoomRouteHandle._(this._coordinator, this.roomId);

  final RoomNavigationCoordinator _coordinator;
  final String roomId;

  /// 当前已登记的活动路由（未登记或已释放为 null）。
  Route<void>? get route => _coordinator.activeRoute(roomId);

  /// 登记活动路由（push 之前调用）。
  ///
  /// 路由一旦建立就同时结束「正在打开」状态：此后同房间请求走
  /// 「已打开 → 回到原页面」，也避免页面退出后租约取消期间把新的打开
  /// 请求并进一个已经不再开新页面的 opening future。
  void register(Route<void> route) {
    _coordinator._active[roomId] = route;
    _coordinator._opening.remove(roomId);
  }

  /// 释放登记：只释放自己登记的那条路由，避免误删后来者。
  void release(Route<void> route) {
    if (identical(_coordinator._active[roomId], route)) {
      _coordinator._active.remove(roomId);
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
  })  : _openRoom = openRoom,
        _navigatorOf = navigatorOf;

  final RoomOpenProcedure _openRoom;
  final NavigatorState? Function() _navigatorOf;
  final Map<String, Future<void>> _opening = {};
  final Map<String, Route<void>> _active = {};
  bool _disposed = false;

  @visibleForTesting
  bool isOpening(String roomId) => _opening.containsKey(roomId.trim());

  @visibleForTesting
  Route<void>? activeRoute(String roomId) => _active[roomId.trim()];

  @visibleForTesting
  int get openingCount => _opening.length;

  @visibleForTesting
  List<String> get activeRoomIds => List.unmodifiable(_active.keys);

  /// 打开（或回到）某个房间。返回值在页面退出、打开失败或复用既有请求时完成。
  Future<void> open(RoomOpenRequest request) {
    final roomId = request.roomId.trim();
    if (roomId.isEmpty || _disposed) return Future<void>.value();

    // 已打开优先于正在打开：打开流程会一直持有到页面关闭，因此「正在打开」
    // 不能覆盖「已打开」，否则再次请求会并进旧的 future 而不是回到原页面。
    final active = _active[roomId];
    if (active != null && active.isActive) {
      // 情况 2：房间已打开——回到原页面，绝不 push 第二层。
      _navigatorOf()?.popUntil((candidate) => identical(candidate, active));
      return Future<void>.value();
    }
    if (active != null) _active.remove(roomId); // 失效登记兜底

    final opening = _opening[roomId];
    if (opening != null) return opening; // 情况 1：合并并发打开

    // 先登记 opening 再启动流程：打开流程在第一个 await 之前会同步执行
    // 「取租约前」的一段（甚至直接 register 路由），必须先占位才能被合并。
    final completer = Completer<void>();
    final pending = completer.future;
    _opening[roomId] = pending;
    unawaited(_run(roomId, request).then((_) {
      if (identical(_opening[roomId], pending)) _opening.remove(roomId);
      if (!completer.isCompleted) completer.complete();
    }, onError: (Object error, StackTrace stackTrace) {
      if (identical(_opening[roomId], pending)) _opening.remove(roomId);
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }));
    return pending;
  }

  Future<void> _run(String roomId, RoomOpenRequest request) async {
    final handle = RoomRouteHandle._(this, roomId);
    try {
      await _openRoom(request, handle);
    } catch (_) {
      // 打开失败不得留下假 active；opening 由 open() 的 whenComplete 清理。
      final route = _active[roomId];
      if (route == null || !route.isActive) _active.remove(roomId);
      rethrow;
    }
  }

  /// 账号切换/退出登录：清空登记，旧账号的房间路由请求不得泄漏到下一个账号。
  void clear() {
    _opening.clear();
    _active.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}
