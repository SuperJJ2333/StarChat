import 'package:flutter/foundation.dart';

import '../contacts/contact_models.dart';
import '../matrix/profile_repository.dart';

/// BUG 3：accept 成功后的本地编排（对应领域事件 friend.accepted）。
///
/// 1. 乐观插入本地好友（SQLite + revision + notify，不等整表网络刷新，
///    禁止要求用户退出 APP 才能看到好友）；
/// 2. 建立/取得加密私聊并发送好友接受系统消息（由 [establishDirectChat]
///    回调完成；失败不回滚好友关系）。
final class FriendAcceptanceCoordinator {
  FriendAcceptanceCoordinator({
    required this.identityCache,
    required this.establishDirectChat,
  });

  final ProfileRepository identityCache;

  /// (matrixUserId, friendUserId, friendDisplayName)。
  final Future<void> Function(
          String matrixUserId, String friendUserId, String friendDisplayName)?
      establishDirectChat;

  Future<void> onAccepted(Map request) async {
    final userId = request['user_id']?.toString();
    final matrixUserId = request['matrix_user_id']?.toString();
    final nickname = (request['nickname']?.toString().isNotEmpty ?? false)
        ? request['nickname'].toString()
        : request['username']?.toString() ?? '好友';

    // 1. 乐观本地插入：通讯录立即出现该好友。
    if (userId != null && userId.isNotEmpty) {
      try {
        // Only this account's existing contact preferences are trusted here.
        // Older servers may include the requester's private preferences.
        ContactSummary? ownContact;
        for (final contact in identityCache.contacts) {
          if (contact.userId == userId) {
            ownContact = contact;
            break;
          }
        }
        await identityCache.applyUpdatedContact(ContactSummary(
          userId: userId,
          username: request['username']?.toString() ?? '',
          matrixUserId: matrixUserId ?? '',
          nickname: nickname,
          avatarUrl: request['avatar_url']?.toString(),
          remark: ownContact?.remark,
          tags: ownContact?.tags ?? const [],
          momentsPermission: ownContact?.momentsPermission ?? 'DEFAULT',
          starred: ownContact?.starred ?? false,
          nudgeSuffix: ownContact?.nudgeSuffix,
        ));
      } catch (_) {
        // 本地插入失败由随后的整表刷新对账。
      }
    }

    // 2/3. 私聊建立 + 系统招呼：失败不阻断好友显示。
    final establish = establishDirectChat;
    if (establish == null || matrixUserId == null || matrixUserId.isEmpty) {
      return;
    }
    try {
      await establish(matrixUserId, userId ?? '', nickname);
    } catch (_) {
      // 会话/系统消息失败后续打开聊天时重试。
    }
  }
}

@visibleForTesting
String friendAcceptedGreeting(String friendDisplayName) =>
    '你已添加了 $friendDisplayName，现在可以开始聊天了。';
