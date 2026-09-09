/// A local presentation projection. Never serialize [displayName] into a
/// message payload: it can contain the viewing account's private remark.
final class UserIdentity {
  const UserIdentity({
    required this.displayName,
    required this.publicDisplayName,
    required this.avatarUrl,
    required this.avatarIsKnown,
    required this.cacheKey,
  });

  final String displayName;
  final String publicDisplayName;
  final String? avatarUrl;

  /// True with a null URL means the authoritative profile cleared its avatar.
  final bool avatarIsKnown;

  /// Account-scoped, stable identity for retained image caches.
  final String cacheKey;
}

String? nonBlankIdentityValue(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String identityDisplayName({
  String? remark,
  String? nickname,
  String? displayName,
  String? username,
  String? matrixUserId,
  String? userId,
}) {
  for (final value in [remark, nickname, displayName, username]) {
    final name = nonBlankIdentityValue(value);
    if (name != null) return name;
  }
  final matrix = nonBlankIdentityValue(matrixUserId);
  if (matrix != null) {
    return matrix.startsWith('@')
        ? matrix.substring(1).split(':').first
        : matrix;
  }
  return nonBlankIdentityValue(userId) ?? '用户';
}
