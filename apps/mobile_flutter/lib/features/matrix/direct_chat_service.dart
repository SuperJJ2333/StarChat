import 'dart:async';

import 'package:matrix/matrix.dart';

import 'conversation_presentation.dart' show ConversationRoomType, conversationRoomType;
import 'direct_chat_controller.dart';
import 'matrix_direct_chat_adapter.dart';

export 'conversation_presentation.dart'
    show ConversationRoomType, conversationRoomType;

/// **LEGACY（生产禁用）**：旧私聊统一服务。
///
/// 生产私聊创建的唯一入口是 `DirectChatController` →
/// `CoordinatedDirectChatGateway`（服务端 canonical 登记 + claim/publish 仲裁）。
/// 本类不含任何跨设备仲裁，直接落到 `createEncryptedDirectRoom`，一旦被生产
/// 复用就会退化成"第二个私聊创建中心"（重复建房）。
///
/// 保留原因：既有单元测试仍以它作为无仲裁基线。
/// 强制手段：`room_opening_policy_test.dart` 的架构守卫断言 `lib/` 中除定义处
/// 外没有调用者（注释不会让 CI 失败，守卫会）。
///
/// `roomIdCache`：friendId→roomId 会话级缓存（打开聊天零重复查询）。
final class DirectChatService {
  DirectChatService(this.backend, {Map<String, String>? seedCache})
      : _cache = seedCache ?? {};

  final MatrixDirectChatBackend backend;
  final Map<String, String> _cache;

  /// 缓存命中（含 m.direct 映射）→ 零网络直接返回。
  String? cachedRoomId(String matrixUserId) => _cache[matrixUserId];

  /// **LEGACY（生产禁用）**：创建或复用私聊（必须复用：绝不重复建房）。
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

/// **LEGACY（生产禁用）**：既有网关门面（openOrCreateDirectChat 语义 =
/// createOrGetDirectChat）。生产请使用 `CoordinatedDirectChatGateway`。
Future<DirectChatRoom> openOrCreateViaGateway(
  DirectChatGateway gateway,
  String matrixUserId,
) =>
    gateway.openOrCreateDirectChat(matrixUserId);
