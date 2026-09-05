import 'dart:developer' as developer;

import 'package:matrix/matrix.dart';

import 'direct_chat_controller.dart';

final class MatrixDirectChatBackend implements DirectChatBackend {
  const MatrixDirectChatBackend(this.client);
  final Client client;

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
      final participants =
          await room.requestParticipants([Membership.join, Membership.invite]);
      if (!participants.any((member) => member.id == matrixUserId)) continue;
      await room.join();
      await client.waitForRoomInSync(room.id, join: true);
      final joined = client.getRoomById(room.id);
      if (joined != null && joined.membership == Membership.join) {
        await joined.addToDirectChat(matrixUserId);
        return _snapshot(joined);
      }
    }
    return null;
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
    try {
      if (snapshot.encrypted &&
          snapshot.participantIds.length == 1 &&
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
        final candidate = await _snapshot(room);
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

  Future<DirectChatRoom> _snapshot(Room room) async {
    // 成员按 join+invite 口径统计：新好友的 DM 在对方接受邀请前只有
    // 一方 joined，会话必须允许该状态存在（否则必报"无法打开加密会话"）。
    final members =
        await room.requestParticipants([Membership.join, Membership.invite]);
    return DirectChatRoom(
      roomId: room.id,
      encrypted: room.encrypted,
      joinedMemberCount: members.length,
      participantIds: members.map((member) => member.id).toSet(),
    );
  }
}
