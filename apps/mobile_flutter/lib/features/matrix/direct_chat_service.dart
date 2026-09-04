import 'dart:async';

import 'package:matrix/matrix.dart';

import 'conversation_presentation.dart' show ConversationRoomType, conversationRoomType;
import 'direct_chat_controller.dart';
import 'matrix_direct_chat_adapter.dart';

export 'conversation_presentation.dart'
    show ConversationRoomType, conversationRoomType;

/// 规格§一：私聊统一服务（唯一入口）。
///
/// 业务层禁止直接 `createRoom()`——一切私聊创建/获取必须经
/// [DirectChatService.createOrGetDirectChat]（底层走 SDK startDirectChat：
/// is_direct=true + invite 对端 + 写 m.direct + 校验双人加密）。
/// [roomIdCache]：friendId→roomId 会话级缓存（打开聊天零重复查询，
/// 规格§七性能链路）。
final class DirectChatService {
  DirectChatService(this.backend, {Map<String, String>? seedCache})
      : _cache = seedCache ?? {};

  final MatrixDirectChatBackend backend;
  final Map<String, String> _cache;

  /// 缓存命中（含 m.direct 映射）→ 零网络直接返回。
  String? cachedRoomId(String matrixUserId) => _cache[matrixUserId];

  /// 创建或复用私聊（必须复用：绝不重复建房）。
  Future<String> createOrGetDirectChat(String matrixUserId) async {
    final cached = _cache[matrixUserId];
    if (cached != null) {
      final room = backend.client.getRoomById(cached);
      if (room != null &&
          room.membership == Membership.join &&
          room.isDirectChat) {
        return cached;
      }
      _cache.remove(matrixUserId); // 缓存失效（退出/被踢）。
    }
    // m.direct 账号数据是第二层权威缓存。
    final viaDirect = backend.client.getDirectChatFromUserId(matrixUserId);
    if (viaDirect != null) {
      final room = backend.client.getRoomById(viaDirect);
      if (room != null &&
          room.membership == Membership.join &&
          room.isDirectChat) {
        _cache[matrixUserId] = viaDirect;
        return viaDirect;
      }
    }
    final room = await backend.createEncryptedDirectRoom(matrixUserId);
    // 底层已保证：isDirect + m.direct 写入校验 + 双人加密（不达标即抛）。
    _cache[matrixUserId] = room;
    return room;
  }

  void invalidate(String matrixUserId) => _cache.remove(matrixUserId);

  /// 集中式房间类型判定（规格§一5：禁止以成员数量判定私聊）。
  static ConversationRoomType roomType(Room room) => conversationRoomType(
        isDirectChat: room.isDirectChat,
        memberCount: room.getParticipants().length,
      );
}

/// 既有网关门面（openOrCreateDirectChat 语义 = createOrGetDirectChat）。
Future<DirectChatRoom> openOrCreateViaGateway(
  DirectChatGateway gateway,
  String matrixUserId,
) =>
    gateway.openOrCreateDirectChat(matrixUserId);
