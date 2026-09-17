import 'package:flutter/foundation.dart';

import '../contacts/contact_models.dart';
import '../contacts/user_display_name_resolver.dart';
import 'avatar_url_resolver.dart';
import 'call_controller.dart';
import 'matrix_user_avatar.dart';

/// 通话对方身份的**唯一**解析入口（Task L）。
///
/// 修复的缺陷：主叫路径用权威联系人（备注/昵称 + 业务头像），被叫路径却只
/// 传 `displayName` + `fallbackSeed`，头像丢失；名称与头像还可能各走一套。
///
/// 优先级（与通讯录一致）：
/// 好友备注 > 好友昵称 > 业务好友头像 > Matrix displayName >
/// Matrix avatar（`mxc://` → 带授权头的缩略图 URL）> username > Matrix ID。
///
/// 安全边界：只读取本机已有资料与 Matrix 媒体；不发起 Business API 请求，
/// 不把 token 放进缓存键，也不把头像 URL 放进任何推送 payload。
final class CallIdentityResolver {
  CallIdentityResolver({
    required this.displayNameResolver,
    this.avatarMedia,
    this.contactFor,
    this.matrixProfileFor,
  });

  /// 名称与业务头像来源（好友缓存投影）。
  final UserDisplayNameResolver displayNameResolver;

  /// Matrix 媒体能力（`mxc://` → 合法缩略图 URL + 授权头）。
  final AvatarMediaCapability? avatarMedia;

  /// 好友快照（用于 `fallbackSeed` 与业务头像判定）。
  final ContactSummary? Function(String matrixUserId)? contactFor;

  /// 该 Matrix 用户的 Matrix 头像 `mxc://`（来自本地 SDK 状态，无网络）。
  final Uri? Function(String matrixUserId)? matrixProfileFor;

  /// 统一解析。任何一步失败都逐级回退，最终一定能返回一个可显示的身份。
  Future<CallIdentity> resolve(
    String matrixUserId, {
    String? matrixDisplayName,
  }) async {
    final contact = contactFor?.call(matrixUserId);
    final displayName = displayNameResolver.resolveSync(
      matrixUserId,
      matrixDisplayName: matrixDisplayName ?? contact?.nickname,
    );
    final fallbackSeed = _fallbackSeed(contact, matrixUserId);
    final identity = CallIdentity(
      matrixUserId: matrixUserId,
      displayName: displayName,
      fallbackSeed: fallbackSeed,
    );

    // 1) 业务好友头像（权威）。
    final businessAvatar = displayNameResolver.avatarUrlFor(matrixUserId);
    if (businessAvatar != null && businessAvatar.isNotEmpty) {
      return identity.copyWith(avatarUrl: businessAvatar);
    }

    // 2) Matrix 头像回退：必须经 MXC resolver 生成合法 thumbnail URL +
    //    authorization headers，绝不能把 mxc:// 当普通 HTTP URL 使用。
    final avatarMedia = this.avatarMedia;
    final avatarUri = matrixProfileFor?.call(matrixUserId);
    if (avatarMedia == null || avatarUri == null) return identity;
    try {
      final resolved = await avatarMedia.resolveAvatar(
        avatarUri: avatarUri,
        size: MatrixAvatarUrlResolver.canonicalThumbnailSize.toDouble(),
      );
      if (resolved == null) return identity;
      return identity.copyWith(
        avatarUrl: resolved.url,
        avatarHeaders: resolved.headers,
        avatarIsMatrixMedia: true,
      );
    } catch (_) {
      // Matrix 媒体能力暂不可用：保留首字回退，绝不显示空白。
      return identity;
    }
  }

  /// 首字回退种子：优先业务 username，其次 Matrix 本地部分。
  static String _fallbackSeed(ContactSummary? contact, String matrixUserId) {
    final username = contact?.username.trim();
    if (username != null && username.isNotEmpty) return username;
    if (matrixUserId.startsWith('@')) {
      return matrixUserId.substring(1).split(':').first;
    }
    if (matrixUserId.trim().isEmpty) return 'incoming-call';
    return matrixUserId;
  }
}

/// 仅为便于单测暴露的纯函数：首字回退种子。
@visibleForTesting
String callFallbackSeed(ContactSummary? contact, String matrixUserId) =>
    CallIdentityResolver._fallbackSeed(contact, matrixUserId);
