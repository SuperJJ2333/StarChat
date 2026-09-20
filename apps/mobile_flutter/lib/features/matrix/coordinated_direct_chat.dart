import '../../core/business_api_error.dart';
import 'direct_chat_controller.dart';

final class DirectRoomClaim {
  const DirectRoomClaim(
      {this.roomId,
      this.mayCreate = false,
      this.canPublish = false,
      this.roomAliasLocalpart,
      this.reservationId});
  final String? roomId;
  final String? roomAliasLocalpart;
  final String? reservationId;
  final bool mayCreate;
  final bool canPublish;
}

abstract interface class DirectRoomCoordinator {
  Future<String?> canonicalRoomId(String peer);
  Future<DirectRoomClaim> claim(String peer, String attemptId);
  Future<String> publish(String peer, String attemptId, String roomId);
}

/// Server authority for both initial creation and later physical generations.
abstract interface class DirectRoomLifecycleCoordinator {
  Future<DirectRoomResolution> resolve(String peer, String attemptId);
  Future<void> offerExistingRoom(String peer, String roomId);
  Future<DirectRoomResolution> publishRecovery(String peer, String attemptId,
      DirectRoomResolution resolution, String roomId);
}

final class DirectRoomResolution {
  const DirectRoomResolution(
      {required this.status,
      required this.generation,
      required this.revision,
      this.roomIds = const [],
      this.roomId,
      this.alias,
      this.reservationId});
  final String status;
  final int generation;
  final int revision;
  final List<String> roomIds;
  final String? roomId, alias, reservationId;
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
    this.createReserved,
    this.onResolved,
    this.ownerToken,
    Future<void> Function(Duration)? wait,
    this.waitAttempts = 20,
  }) : wait = wait ?? Future<void>.delayed;

  final DirectRoomCoordinator coordinator;
  final Future<void> Function(
      String matrixPeer, DirectRoomResolution resolution)? onResolved;
  final Object? Function()? ownerToken;
  final DirectRoomIntentStore intents;
  final String? Function(String) businessUserIdOf;
  final Future<DirectChatRoom> Function(String) createOnce;
  final Future<String> Function(
      String peer, String aliasLocalpart, String reservationId)? createReserved;
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
    final token = ownerToken?.call();
    void validateOwner() {
      if (token != ownerToken?.call()) {
        throw StateError('Conversation owner changed');
      }
    }

    final peer = businessUserIdOf(matrixUserId);
    if (peer == null || peer.isEmpty) {
      throw StateError('好友身份尚未就绪，请重试');
    }
    if (coordinator is DirectRoomLifecycleCoordinator) {
      final lifecycle = coordinator as DirectRoomLifecycleCoordinator;
      final intent = await intents.loadOrCreate(peer);
      validateOwner();
      // Resolve is an idempotent, non-financial preparation step. Keep the
      // original intent and pending send alive for brief throttling, without
      // replaying Matrix creation, publication, or the actual message send.
      // Share this small budget across both resolutions in this opening.
      var retries = 0;
      var waited = Duration.zero;
      Future<DirectRoomResolution> resolve() async {
        while (true) {
          validateOwner();
          try {
            return await lifecycle.resolve(peer, intent.attemptId);
          } on BusinessApiException catch (error) {
            validateOwner();
            if (error.statusCode != 429 || retries >= 2) rethrow;
            final seconds = error.retryAfterSeconds;
            final delay =
                Duration(seconds: seconds != null && seconds > 0 ? seconds : 1);
            // Never shorten Retry-After. Longer throttles remain visible;
            // waiting here must not consume the outer send timeout budget.
            if (waited + delay > const Duration(seconds: 10)) rethrow;
            retries++;
            waited += delay;
            await wait(delay);
            validateOwner();
          }
        }
      }

      var resolution = await resolve();
      validateOwner();
      if (resolution.status == 'create_required' && findCached != null) {
        final cached = await findCached!(matrixUserId);
        validateOwner();
        if (cached != null && _isSafeLocally(cached, matrixUserId)) {
          await lifecycle.offerExistingRoom(peer, cached.roomId);
          validateOwner();
          resolution = await resolve();
          validateOwner();
        }
      }
      if (resolution.status == 'unavailable') {
        throw const DirectRoomPendingException();
      }
      var roomId = resolution.roomId;
      if (resolution.status == 'create_required') {
        final create = createReserved;
        if (create == null) {
          throw StateError('Recoverable room creation unavailable');
        }
        final created = await create(
            matrixUserId, resolution.alias!, resolution.reservationId!);
        validateOwner();
        resolution = await lifecycle.publishRecovery(
            peer, intent.attemptId, resolution, created);
        validateOwner();
        roomId = resolution.roomId;
      }
      if (roomId == null || roomId.isEmpty) {
        throw const DirectRoomPendingException();
      }
      final room =
          _safe(await openExisting(roomId, matrixUserId), matrixUserId);
      validateOwner();
      await onResolved?.call(matrixUserId, resolution);
      validateOwner();
      await intents.saveRoom(peer, intent, room.roomId);
      return room;
    }
    // Opening local history has a separate zero-network API. The coordination
    // path must never accept an unregistered cached room as a sending authority.
    // Only an authoritative absence permits claiming. Network/validation
    // failures propagate; none of them is evidence that another room is needed.
    String? canonical;
    try {
      canonical = await coordinator.canonicalRoomId(peer);
    } catch (error) {
      // 断网降级：规范登记不可达时回退本地（意图存储的房间 + 本地
      // Matrix 库的既有私聊）。已存在的会话离线也能打开；本地完全
      // 没有房间时才把原始网络错误抛给调用方（弹“网络异常”）。
      final localRoomId = (await intents.loadOrCreate(peer)).roomId ??
          (await findExisting(matrixUserId))?.roomId;
      if (localRoomId != null && localRoomId.isNotEmpty) {
        return _safe(
            await openExisting(localRoomId, matrixUserId), matrixUserId);
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
    final alias = claim.roomAliasLocalpart;
    final reservation = claim.reservationId;
    if (claim.mayCreate &&
        claim.canPublish &&
        alias != null &&
        reservation != null) {
      final create = createReserved;
      if (create == null) {
        throw StateError('Recoverable room creation unavailable');
      }
      final created = await create(matrixUserId, alias, reservation);
      await intents.saveRoom(peer, intent, created);
      final published =
          await coordinator.publish(peer, intent.attemptId, created);
      return _safe(await openExisting(published, matrixUserId), matrixUserId);
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
    if (!_isSafeLocally(room, peer)) {
      throw StateError('规范私聊成员或加密状态尚未就绪');
    }
    return room;
  }

  bool _isSafeLocally(DirectChatRoom room, String peer) =>
      room.roomId.isNotEmpty &&
      room.encrypted &&
      room.joinedMemberCount == 2 &&
      room.participantIds.length == 2 &&
      room.participantIds.contains(peer);

  /// **Offline First**：只读本地 SDK 快照，零网络、零副作用、不抛错。
  ///
  /// 这是「先本地后网络」的入口：命中即立刻进入房间；未命中返回 null，
  /// 由调用方决定是后台仲裁还是进入 pending conversation——**绝不**因为
  /// 本地还没有会话就阻塞页面进入或弹错误框。
  @override
  Future<DirectChatRoom?> tryLocalDirectChat(String matrixUserId) async {
    final lookup = findCached;
    if (lookup == null) return null;
    try {
      final cached = await lookup(matrixUserId);
      if (cached == null) return null;
      return _isSafeLocally(cached, matrixUserId) ? cached : null;
    } catch (_) {
      return null;
    }
  }

  /// **Offline First**：本地持久化的房间号提示（协调 intent），零网络。
  @override
  Future<String?> localRoomHint(String matrixUserId) async {
    final peer = businessUserIdOf(matrixUserId);
    if (peer == null || peer.isEmpty) return null;
    try {
      final roomId = (await intents.loadOrCreate(peer)).roomId;
      return (roomId == null || roomId.isEmpty) ? null : roomId;
    } catch (_) {
      return null;
    }
  }
}
