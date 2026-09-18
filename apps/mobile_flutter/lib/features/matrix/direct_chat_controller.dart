import 'dart:async';

import 'package:flutter/foundation.dart';

final class DirectChatRoom {
  const DirectChatRoom({
    required this.roomId,
    required this.encrypted,
    required this.joinedMemberCount,
    required this.participantIds,
  });
  final String roomId;
  final bool encrypted;
  final int joinedMemberCount;
  final Set<String> participantIds;
}

abstract interface class DirectChatBackend {
  Future<DirectChatRoom?> findJoinedDirectRoom(String matrixUserId);

  /// 新建加密私聊。[avoidRoomId] 指定已知不健康（如对方已退出）的旧
  /// 房间：SDK 复用路径命中它时必须绕开，显式新建并重指 m.direct。
  Future<String> createEncryptedDirectRoom(
    String matrixUserId, {
    String? avoidRoomId,
  });

  Future<DirectChatRoom> waitForRoom(String roomId);

  /// 修复不健康的既有私聊（对方已退出→重新邀请；未加密→补开加密）。
  /// 可修复返回新快照，不可修复返回 null（由调用方显式新建）。
  Future<DirectChatRoom?> repairDirectRoom(
    DirectChatRoom room,
    String matrixUserId,
  );
}

abstract interface class DirectChatGateway {
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId);

  /// **Local-only** fast path for Offline First entry.
  ///
  /// Returns the already-safe cached conversation (encrypted, exactly two
  /// members including the peer, known from the SDK's local database) without
  /// any network round trip. Returns `null` when nothing is safely cached —
  /// callers must treat that as "no local room yet", never as an error.
  Future<DirectChatRoom?> tryLocalDirectChat(String matrixUserId);

  /// **Local-only** persisted room id hint for this peer (coordination intent),
  /// or null. Never performs network I/O and never throws.
  Future<String?> localRoomHint(String matrixUserId);
}

final class DirectChatService implements DirectChatGateway {
  const DirectChatService(this.backend);
  final DirectChatBackend backend;

  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) async {
    final existing = await backend.findJoinedDirectRoom(matrixUserId);
    if (existing != null) {
      if (_isSafe(existing, matrixUserId)) return existing;
      // 既有 m.direct 房间不健康（真机 BUG：对方 invite→leave 后
      // “发消息”必报“无法打开加密会话”）。先尝试原地修复保留聊天
      // 历史；不可修复才绕开旧房间显式新建。
      final repaired = await backend.repairDirectRoom(existing, matrixUserId);
      if (repaired != null && _isSafe(repaired, matrixUserId)) return repaired;
      if (existing.participantIds.length < 2 ||
          (existing.participantIds.length == 2 &&
              existing.participantIds.contains(matrixUserId))) {
        throw StateError('Direct chat is not ready; retry the existing room');
      }
      final roomId = await backend.createEncryptedDirectRoom(
        matrixUserId,
        avoidRoomId: existing.roomId,
      );
      return _requireSafe(await backend.waitForRoom(roomId), matrixUserId);
    }
    final roomId = await backend.createEncryptedDirectRoom(matrixUserId);
    return _requireSafe(await backend.waitForRoom(roomId), matrixUserId);
  }

  /// 打开既有规范房间（Canonical Direct Conversation 复用路径）。
  Future<DirectChatRoom> openExisting(
      String roomId, String matrixUserId) async {
    return _requireSafe(await backend.waitForRoom(roomId), matrixUserId);
  }

  /// LEGACY（生产禁用）：本类没有本地优先语义，由
  /// `CoordinatedDirectChatGateway` 提供；这里显式返回 null。
  @override
  Future<DirectChatRoom?> tryLocalDirectChat(String matrixUserId) async => null;

  @override
  Future<String?> localRoomHint(String matrixUserId) async => null;

  bool _isSafe(DirectChatRoom room, String matrixUserId) =>
      room.encrypted &&
      room.joinedMemberCount == 2 &&
      room.participantIds.length == 2 &&
      room.participantIds.contains(matrixUserId);

  DirectChatRoom _requireSafe(DirectChatRoom room, String matrixUserId) {
    if (!_isSafe(room, matrixUserId)) {
      throw StateError('Direct chat must be encrypted and contain two members');
    }
    return room;
  }
}

enum DirectChatState { idle, opening, ready, failed }

/// Canonical Direct Conversation 目录（好友系统重构 Phase E）。
abstract interface class CanonicalDirectRoomDirectory {
  /// 查询与某业务用户的规范私聊房间（无则 null）。
  Future<String?> canonicalRoomId(String peerUserId);

  /// 注册新建房间；返回规范房间号（并发冲突时为既有房间）。
  Future<String?> registerRoom(String peerUserId, String roomId);
}

/// **LEGACY（生产禁用）**：只做"canonical 房间号查询 + 登记"的旧网关。
///
/// 生产用 `CoordinatedDirectChatGateway`（服务端 claim/publish 跨设备仲裁 +
/// 一次性建房授权）；本类没有这些保护，被生产复用会退化成"第二个私聊创建
/// 中心"。保留原因：compatibility 单元测试基线。
/// 强制手段：架构守卫断言 `lib/` 生产代码不构造本类。
final class CanonicalDirectChatGateway implements DirectChatGateway {
  CanonicalDirectChatGateway({
    required DirectChatGateway inner,
    required CanonicalDirectRoomDirectory directory,
    required String? Function(String matrixUserId) businessUserIdOf,
    required Future<DirectChatRoom> Function(String roomId) openExistingRoom,
  })  : _inner = inner,
        _directory = directory,
        _businessUserIdOf = businessUserIdOf,
        _openExistingRoom = openExistingRoom;

  final DirectChatGateway _inner;
  final CanonicalDirectRoomDirectory _directory;
  final String? Function(String matrixUserId) _businessUserIdOf;
  final Future<DirectChatRoom> Function(String roomId) _openExistingRoom;

  DirectChatRoom _forPeer(DirectChatRoom room, String peer) {
    if (!room.encrypted ||
        room.joinedMemberCount != 2 ||
        room.participantIds.length != 2 ||
        !room.participantIds.contains(peer)) {
      throw StateError('Canonical room does not match requested peer');
    }
    return room;
  }

  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) async {
    final peerUserId = _businessUserIdOf(matrixUserId);
    if (peerUserId == null || peerUserId.isEmpty) {
      throw StateError('好友身份尚未就绪');
    }
    final canonical = await _directory.canonicalRoomId(peerUserId);
    if (canonical != null && canonical.isNotEmpty) {
      return _forPeer(await _openExistingRoom(canonical), matrixUserId);
    }
    final room = await _inner.openOrCreateDirectChat(matrixUserId);
    final effective = await _directory.registerRoom(peerUserId, room.roomId);
    if (effective == null || effective.isEmpty) {
      throw StateError('规范私聊登记未完成');
    }
    if (effective != room.roomId) {
      return _forPeer(await _openExistingRoom(effective), matrixUserId);
    }
    return _forPeer(room, matrixUserId);
  }

  /// LEGACY（生产禁用）：本地优先语义由被包裹的网关上提供。
  @override
  Future<DirectChatRoom?> tryLocalDirectChat(String matrixUserId) =>
      _inner.tryLocalDirectChat(matrixUserId);

  @override
  Future<String?> localRoomHint(String matrixUserId) =>
      _inner.localRoomHint(matrixUserId);
}

final class DirectChatController extends ChangeNotifier {
  DirectChatController(this.gateway);
  final DirectChatGateway gateway;
  DirectChatState state = DirectChatState.idle;
  Object? error;
  String? _lastMatrixUserId;
  final Map<String, Future<DirectChatRoom>> _openings = {};

  Future<DirectChatRoom> open(String matrixUserId) async {
    final pending = _openings[matrixUserId];
    if (pending != null) return pending;
    _lastMatrixUserId = matrixUserId;
    state = DirectChatState.opening;
    error = null;
    notifyListeners();
    final opening = gateway.openOrCreateDirectChat(matrixUserId);
    _openings[matrixUserId] = opening;
    try {
      final room = await opening;
      state = DirectChatState.ready;
      notifyListeners();
      return room;
    } catch (failure) {
      state = DirectChatState.failed;
      error = failure;
      notifyListeners();
      rethrow;
    } finally {
      if (identical(_openings[matrixUserId], opening)) {
        _openings.remove(matrixUserId);
      }
    }
  }

  /// **Offline First 入口**：只读本地缓存/持久化提示，不做任何网络请求，
  /// 也不因“本地还没有会话”而抛错。
  ///
  /// 返回的 roomId 交给 `RoomOpeningPolicy` 判定：本地已加入 → 立即打开
  /// （零等待）；本地已知但未加入 → 由策略按来源决定立即打开或短等待。
  Future<DirectChatRoom?> tryLocal(String matrixUserId) async {
    if (matrixUserId.trim().isEmpty) return null;
    try {
      return await gateway.tryLocalDirectChat(matrixUserId);
    } catch (_) {
      return null;
    }
  }

  /// 本地持久化的房间号提示（协调 intent），用于本地已有会话但 SDK 快照
  /// 尚未完整时的无网进入。绝不联网、绝不抛错。
  Future<String?> localRoomHint(String matrixUserId) async {
    if (matrixUserId.trim().isEmpty) return null;
    try {
      return await gateway.localRoomHint(matrixUserId);
    } catch (_) {
      return null;
    }
  }

  Future<DirectChatRoom> retry() {
    final matrixUserId = _lastMatrixUserId;
    if (matrixUserId == null) throw StateError('No direct chat to retry');
    return open(matrixUserId);
  }
}
