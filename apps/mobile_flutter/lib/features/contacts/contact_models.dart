import 'user_identity.dart';

final class ContactSummary {
  const ContactSummary({
    required this.userId,
    required this.username,
    required this.matrixUserId,
    this.nickname,
    this.remark,
    this.avatarUrl,
    this.avatarIsKnown = true,
    this.nudgeSuffix,
    this.momentsPermission = 'DEFAULT',
    this.tags = const [],
    this.starred = false,
    this.lastSeenAt,
  });

  factory ContactSummary.fromJson(Map<String, dynamic> json) => ContactSummary(
        userId: json['user_id'] as String,
        username: json['username'] as String,
        matrixUserId: json['matrix_user_id'] as String,
        nickname: json['nickname']?.toString(),
        remark: json['remark']?.toString(),
        avatarUrl: json['avatar_url']?.toString(),
        avatarIsKnown: json.containsKey('avatar_url'),
        nudgeSuffix: json['nudge_suffix']?.toString(),
        momentsPermission: json['moments_permission']?.toString() ?? 'DEFAULT',
        tags: (json['tags'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(growable: false),
        starred: json['starred'] == true,
        lastSeenAt: DateTime.tryParse(json['last_seen_at']?.toString() ?? ''),
      );

  final String userId;
  final String username;
  final String matrixUserId;
  final String? nickname;
  final String? remark;
  final String? avatarUrl;
  final bool avatarIsKnown;
  final String? nudgeSuffix;
  final String momentsPermission;
  final List<String> tags;
  final bool starred;

  /// 该好友最近一次使用 App 的时间（服务端设备 last_seen_at 最大值）；
  /// null 表示暂无记录。仅好友资料页在线状态栏使用。
  final DateTime? lastSeenAt;

  bool get isStarred =>
      starred || tags.any((tag) => tag == 'starred' || tag == '星标好友');

  String get displayName => identityDisplayName(
      remark: remark,
      nickname: nickname,
      username: username,
      matrixUserId: matrixUserId,
      userId: userId);

  /// Public identity for outgoing payloads. Local presentation uses displayName.
  String get primaryDisplayName => identityDisplayName(
      nickname: nickname,
      username: username,
      matrixUserId: matrixUserId,
      userId: userId);

  ContactSummary copyWith(
          {String? remark,
          String? nickname,
          String? avatarUrl,
          bool? avatarIsKnown}) =>
      ContactSummary(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname ?? this.nickname,
        remark: remark ?? this.remark,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        avatarIsKnown: avatarIsKnown ?? this.avatarIsKnown,
        nudgeSuffix: nudgeSuffix,
        momentsPermission: momentsPermission,
        tags: tags,
        starred: starred,
        lastSeenAt: lastSeenAt,
      );

  ContactDetails toDetails() => ContactDetails(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname,
        remark: remark,
        avatarUrl: avatarUrl,
        avatarIsKnown: avatarIsKnown,
        nudgeSuffix: nudgeSuffix,
        momentsPermission: momentsPermission,
        tags: tags,
        starred: starred,
        lastSeenAt: lastSeenAt,
      );
}

/// 好友资料页在线状态文案（按最近一次使用 App 时间动态展示）：
/// - null / 解析失败：暂无在线记录
/// - <1 分钟：刚刚在线；<1 小时：N分钟前在线；<24 小时：N小时前在线
/// - <7 天：N天前在线；≥7 天：YYYY-MM-DD HH:mm 在线
String formatLastSeenLabel(DateTime? lastSeen, {DateTime? now}) {
  if (lastSeen == null) return '暂无在线记录';
  final difference = (now ?? DateTime.now()).difference(lastSeen.toLocal());
  if (difference.isNegative) return '刚刚在线';
  if (difference.inMinutes < 1) return '刚刚在线';
  if (difference.inHours < 1) return '${difference.inMinutes}分钟前在线';
  if (difference.inHours < 24) return '${difference.inHours}小时前在线';
  if (difference.inDays < 7) return '${difference.inDays}天前在线';
  final local = lastSeen.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)} 在线';
}

final class ContactDetails {
  const ContactDetails({
    required this.userId,
    required this.username,
    required this.matrixUserId,
    this.nickname,
    this.remark,
    this.avatarUrl,
    this.avatarIsKnown = true,
    this.nudgeSuffix,
    this.momentsPermission = 'DEFAULT',
    this.tags = const [],
    this.starred = false,
    this.lastSeenAt,
  });

  final String userId;
  final String username;
  final String matrixUserId;
  final String? nickname;
  final String? remark;
  final String? avatarUrl;
  final bool avatarIsKnown;
  final String? nudgeSuffix;
  final String momentsPermission;
  final List<String> tags;
  final bool starred;

  /// 好友最近一次使用 App 的时间（同 [ContactSummary.lastSeenAt]）。
  final DateTime? lastSeenAt;

  String get displayName => ContactSummary(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname,
        remark: remark,
      ).displayName;

  /// Public identity for outgoing payloads, without the viewer's private remark.
  String get primaryDisplayName => ContactSummary(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname,
      ).primaryDisplayName;

  ContactSummary toSummary() => ContactSummary(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname,
        remark: remark,
        avatarUrl: avatarUrl,
        avatarIsKnown: avatarIsKnown,
        nudgeSuffix: nudgeSuffix,
        momentsPermission: momentsPermission,
        tags: List.unmodifiable(tags),
        starred: starred,
      );

  ContactDetails copyWith({
    String? remark,
    bool clearRemark = false,
    List<String>? tags,
    String? momentsPermission,
  }) =>
      ContactDetails(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname,
        remark: clearRemark ? null : remark ?? this.remark,
        avatarUrl: avatarUrl,
        avatarIsKnown: avatarIsKnown,
        nudgeSuffix: nudgeSuffix,
        momentsPermission: momentsPermission ?? this.momentsPermission,
        tags: tags ?? this.tags,
        starred: starred,
      );
}

/// 添加朋友：畅聊号/邮箱前缀搜索 + 好友申请（含备注/标签/朋友圈权限）。
abstract interface class AddFriendGateway {
  Future<Map<String, dynamic>> searchUsers(String query);
  Future<Map<String, dynamic>> requestFriend(
    String userId, {
    String message,
    String? remark,
    List<String> tags,
    String momentsPermission,
  });
  Future<Map<String, dynamic>> contactTags();
}

abstract interface class ContactsGateway {
  Future<List<ContactSummary>> listContacts();
  Future<Map<String, dynamic>> contactTags();
  Future<Map<String, dynamic>> createContactTag(String name);
  Future<Map<String, dynamic>> renameContactTag(String id, String name);
  Future<void> deleteContactTag(String id);
  Future<void> deleteContactTags(List<String> ids);
  Future<ContactDetails> updateContactDetails(
    ContactDetails contact, {
    required String? remark,
    required List<String> tags,
    required String momentsPermission,
  });
  Future<void> blockContact(String userId);
  Future<void> deleteContact(String userId);
}
