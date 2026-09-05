import 'contact_models.dart';

/// 用户显示名称统一解析（规格#2）：来电页/通话记录/通知栏共用。
///
/// 优先级：好友备注 > 好友昵称 > Matrix displayName > username > Matrix ID。
/// CallPage 禁止直接显示 remoteUserId——一律经本解析器。
abstract interface class UserDisplayNameResolver {
  /// 同步解析（通知/来电即时路径：好友缓存已在内存）。
  String resolveSync(String matrixUserId, {String? matrixDisplayName});

  /// 异步解析（可等待资料加载后补全；超时/失败回退同步结果）。
  Future<String> resolve(String matrixUserId, {String? matrixDisplayName});

  /// 好友业务头像 URL（通知大图标；无好友关系/无头像返回 null）。
  String? avatarUrlFor(String matrixUserId);
}

/// 好友缓存支撑的默认实现（[contactFor] 由组合根注入 ProfileRepository
/// 的同步快照；null 安全：缓存未加载时逐级回退）。
final class ContactBackedUserDisplayNameResolver
    implements UserDisplayNameResolver {
  ContactBackedUserDisplayNameResolver({
    required this.contactFor,
    this.warmContacts,
    this.timeout = const Duration(milliseconds: 800),
  });

  /// 按Matrix用户ID查好友快照（无则 null）。
  final ContactSummary? Function(String matrixUserId) contactFor;

  @override
  String? avatarUrlFor(String matrixUserId) =>
      contactFor(matrixUserId)?.avatarUrl;

  /// 可选：预热好友缓存（登录后已加载则立即完成）。
  final Future<void> Function()? warmContacts;

  final Duration timeout;

  @override
  String resolveSync(String matrixUserId, {String? matrixDisplayName}) {
    final contact = contactFor(matrixUserId);
    final remark = contact?.remark;
    if (remark != null && remark.isNotEmpty) return remark;
    final nickname = contact?.nickname;
    if (nickname != null && nickname.isNotEmpty) return nickname;
    final matrixName = matrixDisplayName?.trim();
    if (matrixName != null && matrixName.isNotEmpty) return matrixName;
    final username = contact?.username;
    if (username != null && username.isNotEmpty) return username;
    return matrixUserId;
  }

  @override
  Future<String> resolve(String matrixUserId,
      {String? matrixDisplayName}) async {
    final syncResult = resolveSync(matrixUserId, matrixDisplayName: matrixDisplayName);
    final warm = warmContacts;
    if (warm == null) return syncResult;
    try {
      await warm().timeout(timeout);
    } catch (_) {
      return syncResult; // 预热失败/超时：用同步结果（绝不抛出到 UI）。
    }
    return resolveSync(matrixUserId, matrixDisplayName: matrixDisplayName);
  }
}
