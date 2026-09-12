import 'dart:developer' as developer;

import 'package:matrix/matrix.dart';

import 'direct_chat_controller.dart';

final class MatrixDirectChatBackend implements DirectChatBackend {
  const MatrixDirectChatBackend(this.client);
  final Client client;

  /// Open the business directory's canonical room, including an invitation
  /// that has not yet appeared in the local room list.
  Future<DirectChatRoom> openCanonicalRoom(String roomId,
      {String? matrixUserId}) async {
    var room = client.getRoomById(roomId);
    if (room == null || room.membership != Membership.join) {
      await client.joinRoomById(roomId).timeout(const Duration(seconds: 15));
      if (client.getRoomById(roomId)?.membership != Membership.join) {
        await client
            .waitForRoomInSync(roomId, join: true)
            .timeout(const Duration(seconds: 15));
      }
      room = client.getRoomById(roomId);
    }
    var snapshot = await waitForRoom(roomId);
    // The clicked contact supplies the peer; account metadata may be absent or
    // stale. Legacy callers can infer it only when they have enough room state.
    final target = matrixUserId ??
        room?.directChatMatrixID ??
        snapshot.participantIds
            .firstWhere((id) => id != client.userID, orElse: () => '');
    // 问题三（重复会话根因一）：成员/加密状态可能尚未同步送达，此前
    // 校验失败立即抛错、上层回落新建第二个私聊。现在有界等待收敛；
    // 仍不健康则修复（重邀已退出的对方/补开加密，保留聊天历史）；
    // 仍不可用时保留原房间重试，不能借校验失败创建重复房间。
    snapshot = await _ensureHealthy(
      snapshot,
      target: target,
      me: client.userID ?? '',
    );
    if (target.isNotEmpty &&
        (room?.isDirectChat != true || room?.directChatMatrixID != target)) {
      try {
        // m.direct is account data. It does not produce a room sync event.
        await Room(id: roomId, client: client)
            .addToDirectChat(target)
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        // Metadata repair can be retried when this room is opened again.
      }
    }
    return snapshot;
  }

  /// 等待规范房间快照达到“加密+双人”健康态：先短轮询（同步送达），
  /// 不收敛再走 [repairDirectRoom]（重邀/补加密），修复后复验。
  /// 全部失败抛 [StateError]，由用户重试原房间。
  Future<DirectChatRoom> _ensureHealthy(
    DirectChatRoom snapshot, {
    required String target,
    required String me,
  }) async {
    if (_isHealthy(snapshot, target: target, me: me)) return snapshot;
    final room = client.getRoomById(snapshot.roomId);
    if (room == null || target.isEmpty || me.isEmpty || target == me) {
      throw StateError('Direct chat identity or room is unavailable');
    }
    // requestParticipants may return a complete but stale local cache.
    snapshot = await _snapshot(room, refreshMembers: true);
    if (_isHealthy(snapshot, target: target, me: me)) return snapshot;
    for (var attempt = 0; attempt < 4; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final candidate = await _snapshot(room, refreshMembers: true);
      if (_isHealthy(candidate, target: target, me: me)) return candidate;
      snapshot = candidate;
    }
    final repaired = await repairDirectRoom(snapshot, target);
    if (repaired != null && _isHealthy(repaired, target: target, me: me)) {
      return repaired;
    }
    throw StateError(
        'Canonical room is not a healthy direct chat (room=${snapshot.roomId} '
        'encrypted=${snapshot.encrypted} members=${snapshot.joinedMemberCount})');
  }

  bool _isHealthy(
    DirectChatRoom room, {
    required String target,
    required String me,
  }) =>
      room.encrypted &&
      room.joinedMemberCount == 2 &&
      room.participantIds.length == 2 &&
      room.participantIds.contains(target) &&
      room.participantIds.contains(me);

  @override
  Future<DirectChatRoom?> findJoinedDirectRoom(String matrixUserId) async {
    final roomId = client.getDirectChatFromUserId(matrixUserId);
    if (roomId != null) {
      final room = client.getRoomById(roomId);
      if (room != null &&
          room.membership == Membership.join &&
          room.isDirectChat) {
        return _snapshot(room);
      }
    }
    // 新好友场景：对方创建 DM 后我方尚处于「受邀未加入」状态。自动接受
    // 邀请并补写 m.direct，否则会重复建第二个房间或直接报错。
    for (final room in client.rooms) {
      if (room.membership != Membership.invite || !room.isDirectChat) continue;
      // Invited users cannot request /members yet. Use stripped invite state.
      final invitation = room.getState(EventTypes.RoomMember, client.userID!);
      if (invitation?.senderId != matrixUserId ||
          invitation?.content['is_direct'] != true ||
          room.directChatMatrixID != matrixUserId) {
        continue;
      }
      await room.join();
      if (client.getRoomById(room.id)?.membership != Membership.join) {
        await client
            .waitForRoomInSync(room.id, join: true)
            .timeout(const Duration(seconds: 15));
      }
      final joined = client.getRoomById(room.id);
      if (joined != null && joined.membership == Membership.join) {
        await joined.addToDirectChat(matrixUserId);
        return _snapshot(joined);
      }
    }
    return null;
  }

  /// Reads only already-synced local state. This deliberately never calls
  /// requestParticipants, join, repair, or any Matrix endpoint.
  Future<DirectChatRoom?> findCachedJoinedDirectRoom(
      String matrixUserId) async {
    final roomId = client.getDirectChatFromUserId(matrixUserId);
    final room = roomId == null ? null : client.getRoomById(roomId);
    final me = client.userID;
    if (room == null ||
        me == null ||
        room.membership != Membership.join ||
        !room.encrypted ||
        !room.isDirectChat ||
        room.directChatMatrixID != matrixUserId) {
      return null;
    }
    // Lazy room state may omit a member that is already persisted locally.
    // Hydrate only from the SDK database; unlike requestParticipants this can
    // never issue /members or change membership.
    if (!room.participantListComplete) {
      final List<User> storedMembers;
      try {
        storedMembers = await client.database?.getUsers(room) ?? const [];
      } catch (_) {
        // A local cache failure is inconclusive. Let the existing canonical
        // coordinator decide when an authoritative service path is available.
        return null;
      }
      for (final member in storedMembers) {
        // A sync event may have reached memory while the database read was
        // pending. Never replace that newer state with an older persisted
        // member record.
        if (room.getState(EventTypes.RoomMember, member.id) == null) {
          room.setState(member);
        }
      }
    }
    // The database read is asynchronous. Recheck every trust boundary after
    // it completes so a concurrent leave, encryption removal, or m.direct
    // update cannot turn an old snapshot into a local recovery result.
    if (room.membership != Membership.join ||
        !room.encrypted ||
        !room.isDirectChat ||
        room.directChatMatrixID != matrixUserId ||
        room.partial ||
        !room.participantListComplete) {
      return null;
    }
    // Include every locally-known active membership here. A pending knock is
    // still an additional participant and must make local recovery defer.
    final members = room.getParticipants();
    final byId = {for (final member in members) member.id: member};
    final self = byId[me];
    final peer = byId[matrixUserId];
    // A joined self and a joined-or-invited peer are a safe existing direct
    // room. The invitation can be accepted later without discarding already
    // cached history. Any other active participant remains inconclusive.
    if (byId.length != 2 ||
        self?.membership != Membership.join ||
        (peer?.membership != Membership.join &&
            peer?.membership != Membership.invite)) {
      return null;
    }
    return DirectChatRoom(
      roomId: room.id,
      encrypted: true,
      joinedMemberCount: 2,
      participantIds: byId.keys.toSet(),
    );
  }

  @override
  Future<String> createEncryptedDirectRoom(
    String matrixUserId, {
    String? avoidRoomId,
  }) async {
    // BUG 4（Android 9 直聊变二人群聊）：统一走 SDK 的
    // startDirectChat——内部完成 已有DM复用/受邀加入/isDirect 创建/
    // 等待同步/写 m.direct。显式 enableEncryption: true，避免 SDK 在
    // "对方尚未上传密钥"时静默降级为明文房间。
    final directBefore = client.directChats.containsKey(matrixUserId);
    var roomId = await client.startDirectChat(
      matrixUserId,
      enableEncryption: true,
      waitForSync: true,
      preset: CreateRoomPreset.trustedPrivateChat,
    );
    if (avoidRoomId != null && roomId == avoidRoomId) {
      // SDK 的复用路径命中了已知不健康的旧房间（如对方已退出）：
      // 显式新建加密房间并重指 m.direct，绝不再返回坏房间。
      roomId = await client.createRoom(
        invite: [matrixUserId],
        isDirect: true,
        preset: CreateRoomPreset.trustedPrivateChat,
        initialState: [
          StateEvent(
            type: EventTypes.Encryption,
            content: {
              'algorithm': Client.supportedGroupEncryptionAlgorithms.first,
            },
          ),
        ],
      );
      await client.waitForRoomInSync(roomId, join: true);
      await Room(id: roomId, client: client).addToDirectChat(matrixUserId);
    }
    // m.direct 元数据写入与本地同步存在时序差（API 28 等设备尤甚）：
    // 建房后必须校验 isDirect 与 directChatMatrixID，未同步则补写并等待，
    // 绝不把尚未同步的房间永久缓存为群聊。
    var room = client.getRoomById(roomId);
    var directAfter = room?.isDirectChat ?? false;
    var directTarget = room?.directChatMatrixID;
    if (!directAfter || directTarget != matrixUserId) {
      await Room(id: roomId, client: client).addToDirectChat(matrixUserId);
      for (var attempt = 0; attempt < 3; attempt++) {
        await client.waitForRoomInSync(roomId, join: true);
        room = client.getRoomById(roomId);
        directAfter = room?.isDirectChat ?? false;
        directTarget = room?.directChatMatrixID;
        if (directAfter && directTarget == matrixUserId) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    _logDirectChatCreation(
      roomId: roomId,
      targetUserId: matrixUserId,
      mDirectBefore: directBefore,
      mDirectAfter: directAfter,
      room: room,
    );
    if (!directAfter || directTarget != matrixUserId) {
      throw StateError(
          'Direct chat m.direct metadata not synced (room=$roomId target=$matrixUserId '
          'isDirect=$directAfter directTarget=$directTarget)');
    }
    return roomId;
  }

  @override
  Future<DirectChatRoom?> repairDirectRoom(
    DirectChatRoom snapshot,
    String matrixUserId,
  ) async {
    final room = client.getRoomById(snapshot.roomId);
    if (room == null || room.membership != Membership.join) return null;
    if (matrixUserId.isEmpty || matrixUserId == client.userID) return null;
    try {
      snapshot = await _snapshot(room, refreshMembers: true);
      if (_isHealthy(snapshot, target: matrixUserId, me: client.userID ?? '')) {
        return snapshot;
      }
      if (snapshot.encrypted &&
          snapshot.participantIds.length == 1 &&
          snapshot.participantIds.contains(client.userID) &&
          !snapshot.participantIds.contains(matrixUserId)) {
        // 对方已退出（invite→leave）：重新邀请恢复会话，保留聊天历史。
        // invite 计入双人校验；对端打开会话时经 invite 扫描自动接受。
        await room.invite(matrixUserId);
      } else if (!snapshot.encrypted &&
          snapshot.participantIds.length == 2 &&
          snapshot.participantIds.contains(matrixUserId)) {
        // 双人房间但未加密：补发 m.room.encryption 状态事件。
        await room.enableEncryption();
      } else {
        return null;
      }
      // 成员来自服务端实时查询；加密标志依赖本地同步送达，短暂轮询。
      for (var attempt = 0; attempt < 3; attempt++) {
        final candidate = await _snapshot(room, refreshMembers: true);
        if (candidate.encrypted &&
            candidate.participantIds.length == 2 &&
            candidate.participantIds.contains(matrixUserId)) {
          return candidate;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// BUG 4：结构化诊断日志（一次性 debug 级，不记录消息内容）。
  void _logDirectChatCreation({
    required String roomId,
    required String targetUserId,
    required bool mDirectBefore,
    required bool mDirectAfter,
    Room? room,
  }) {
    developer.log(
      'DirectChatCreate sdkInt=${_androidSdkInt()} roomId=$roomId '
      'target=$targetUserId isDirectRequest=true '
      'mDirectBefore=$mDirectBefore mDirectAfter=$mDirectAfter '
      'roomIsDirect=${room?.isDirectChat} roomDirectTarget=${room?.directChatMatrixID} '
      'encrypted=${room?.encrypted} waitForSync=true '
      'dbPersisted=${room != null}',
      name: 'DirectChat',
    );
  }

  String? _androidSdkInt() {
    // 平台版本经 defaultTargetPlatform 间接推断不可靠；此处仅记录
    // Matrix SDK 本地库是否已持久化房间（dbPersisted）。完整 sdkInt
    // 日志由 MainActivity 侧补充（见 DIRECT_CHAT_ANDROID_COMPATIBILITY）。
    return 'see-native-log';
  }

  @override
  Future<DirectChatRoom> waitForRoom(String roomId) async {
    var room = client.getRoomById(roomId);
    if (room == null || room.membership != Membership.join) {
      await client.waitForRoomInSync(roomId, join: true);
      room = client.getRoomById(roomId);
    }
    if (room == null) throw StateError('Created Matrix room is unavailable');
    return _snapshot(room);
  }

  Future<DirectChatRoom> _snapshot(Room room,
      {bool refreshMembers = false}) async {
    // 成员按 join+invite 口径统计：新好友的 DM 在对方接受邀请前只有
    // 一方 joined，会话必须允许该状态存在（否则必报"无法打开加密会话"）。
    final members = refreshMembers
        ? (await client
                .getMembersByRoom(room.id)
                .timeout(const Duration(seconds: 15)))
            ?.map((event) => Event.fromMatrixEvent(event, room).asUser)
            .where((user) =>
                user.membership == Membership.join ||
                user.membership == Membership.invite)
            .toList()
        : await room
            .requestParticipants([Membership.join, Membership.invite]).timeout(
                const Duration(seconds: 15));
    if (members == null) {
      throw StateError('Direct chat members are unavailable');
    }
    return DirectChatRoom(
      roomId: room.id,
      encrypted: room.encrypted,
      joinedMemberCount: members.length,
      participantIds: members.map((member) => member.id).toSet(),
    );
  }
}
