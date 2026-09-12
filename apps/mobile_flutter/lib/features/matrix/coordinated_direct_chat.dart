import 'direct_chat_controller.dart';

final class DirectRoomClaim {
  const DirectRoomClaim(
      {this.roomId, this.mayCreate = false, this.canPublish = false});
  final String? roomId;
  final bool mayCreate;
  final bool canPublish;
}

abstract interface class DirectRoomCoordinator {
  Future<String?> canonicalRoomId(String peer);
  Future<DirectRoomClaim> claim(String peer, String attemptId);
  Future<String> publish(String peer, String attemptId, String roomId);
}

final class DirectRoomIntent {
  const DirectRoomIntent({required this.attemptId, this.roomId});
  final String attemptId;
  final String? roomId;
}

abstract interface class DirectRoomIntentStore {
  Future<DirectRoomIntent> loadOrCreate(String peer);
  Future<void> saveRoom(String peer, DirectRoomIntent intent, String roomId);
}

final class DirectRoomPendingException implements Exception {
  const DirectRoomPendingException();
  @override
  String toString() => '私聊正在同步，请稍后重试；不会重复创建房间。';
}

final class CoordinatedDirectChatGateway implements DirectChatGateway {
  CoordinatedDirectChatGateway({
    required this.coordinator,
    required this.intents,
    required this.businessUserIdOf,
    required this.createOnce,
    required this.findExisting,
    required this.openExisting,
    this.findCached,
    Future<void> Function(Duration)? wait,
    this.waitAttempts = 20,
  }) : wait = wait ?? Future<void>.delayed;

  final DirectRoomCoordinator coordinator;
  final DirectRoomIntentStore intents;
  final String? Function(String) businessUserIdOf;
  final Future<DirectChatRoom> Function(String) createOnce;
  final Future<DirectChatRoom?> Function(String) findExisting;

  /// Local-only, already-validated snapshot. It must never join, repair, or
  /// fetch members; a miss proceeds to authoritative coordination.
  final Future<DirectChatRoom?> Function(String)? findCached;
  final Future<DirectChatRoom> Function(String roomId, String matrixUserId)
      openExisting;
  final Future<void> Function(Duration) wait;
  final int waitAttempts;

  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) async {
    final peer = businessUserIdOf(matrixUserId);
    if (peer == null || peer.isEmpty) {
      throw StateError('好友身份尚未就绪，请重试');
    }
    final cached = await findCached?.call(matrixUserId);
    if (cached != null) return _safe(cached, matrixUserId);
    // Only an authoritative absence permits claiming. Network/validation
    // failures propagate; none of them is evidence that another room is needed.
    String? canonical;
    try {
      canonical = await coordinator.canonicalRoomId(peer);
    } catch (error) {
      // 断网降级：规范登记不可达时回退本地（意图存储的房间 + 本地
      // Matrix 库的既有私聊）。已存在的会话离线也能打开；本地完全
      // 没有房间时才把原始网络错误抛给调用方（弹“网络异常”）。
      final localRoomId =
          (await intents.loadOrCreate(peer)).roomId ?? (await findExisting(matrixUserId))?.roomId;
      if (localRoomId != null && localRoomId.isNotEmpty) {
        return _safe(await openExisting(localRoomId, matrixUserId), matrixUserId);
      }
      rethrow;
    }
    if (canonical != null && canonical.isNotEmpty) {
      return _safe(await openExisting(canonical, matrixUserId), matrixUserId);
    }
    final intent = await intents.loadOrCreate(peer);
    final claim = await coordinator.claim(peer, intent.attemptId);
    final claimedRoom = claim.roomId;
    if (claimedRoom != null && claimedRoom.isNotEmpty) {
      return _safe(await openExisting(claimedRoom, matrixUserId), matrixUserId);
    }
    DirectChatRoom? result;
    if (claim.mayCreate && claim.canPublish) {
      // This grant is returned once by the server. A lost response or an
      // uncertain Matrix result must never replay the create operation.
      final existing = await findExisting(matrixUserId);
      result = existing != null
          ? _safe(
              await openExisting(existing.roomId, matrixUserId), matrixUserId)
          : _safe(await createOnce(matrixUserId), matrixUserId);
    } else if (claim.canPublish) {
      final savedRoom = intent.roomId;
      final existingRoomId =
          savedRoom ?? (await findExisting(matrixUserId))?.roomId;
      if (existingRoomId != null) {
        result = _safe(
            await openExisting(existingRoomId, matrixUserId), matrixUserId);
      }
    }
    if (result != null) {
      await intents.saveRoom(peer, intent, result.roomId);
      final published =
          await coordinator.publish(peer, intent.attemptId, result.roomId);
      if (published.isEmpty) throw StateError('规范私聊登记未完成');
      return published == result.roomId
          ? result
          : _safe(await openExisting(published, matrixUserId), matrixUserId);
    }
    for (var i = 0; i < waitAttempts; i++) {
      await wait(const Duration(milliseconds: 500));
      final ready = await coordinator.canonicalRoomId(peer);
      if (ready != null && ready.isNotEmpty) {
        return _safe(await openExisting(ready, matrixUserId), matrixUserId);
      }
    }
    throw const DirectRoomPendingException();
  }

  DirectChatRoom _safe(DirectChatRoom room, String peer) {
    if (room.roomId.isEmpty ||
        !room.encrypted ||
        room.joinedMemberCount != 2 ||
        room.participantIds.length != 2 ||
        !room.participantIds.contains(peer)) {
      throw StateError('规范私聊成员或加密状态尚未就绪');
    }
    return room;
  }
}
