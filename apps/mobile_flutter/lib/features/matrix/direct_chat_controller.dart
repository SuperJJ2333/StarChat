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

/// Canonical Direct Chat 包装网关：创建私聊前先查规范房间复用，
/// 不存在才走 inner（startDirectChat 路径）创建并注册。
/// 目录/注册失败静默回落 inner（弱网不阻断私聊）。
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
      return _inner.openOrCreateDirectChat(matrixUserId);
    }
    String? canonical;
    try {
      canonical = await _directory.canonicalRoomId(peerUserId);
    } catch (_) {
      canonical = null;
    }
    if (canonical != null && canonical.isNotEmpty) {
      try {
        return _forPeer(await _openExistingRoom(canonical), matrixUserId);
      } catch (_) {
        // 规范房间不可用（如对端重建）：回落新建并重新注册。
      }
    }
    final room = await _inner.openOrCreateDirectChat(matrixUserId);
    try {
      final effective = await _directory.registerRoom(peerUserId, room.roomId);
      if (effective != null &&
          effective.isNotEmpty &&
          effective != room.roomId) {
        // 并发双开：弃用本次房间，采用规范房间。
        return _forPeer(await _openExistingRoom(effective), matrixUserId);
      }
    } catch (_) {
      // 目录异常或规范房间已失效（如对端退出后被替换）：采用本次新建的
      // 有效房间，禁止因失效的登记死锁报错。
    }
    return room;
  }
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

  Future<DirectChatRoom> retry() {
    final matrixUserId = _lastMatrixUserId;
    if (matrixUserId == null) throw StateError('No direct chat to retry');
    return open(matrixUserId);
  }
}
