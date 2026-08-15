final class ContactSummary {
  const ContactSummary({
    required this.userId,
    required this.username,
    required this.matrixUserId,
    this.nickname,
    this.remark,
    this.avatarUrl,
    this.momentsPermission = 'DEFAULT',
    this.tags = const [],
  });

  factory ContactSummary.fromJson(Map<String, dynamic> json) => ContactSummary(
        userId: json['user_id'] as String,
        username: json['username'] as String,
        matrixUserId: json['matrix_user_id'] as String,
        nickname: json['nickname']?.toString(),
        remark: json['remark']?.toString(),
        avatarUrl: json['avatar_url']?.toString(),
        momentsPermission: json['moments_permission']?.toString() ?? 'DEFAULT',
        tags: (json['tags'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(growable: false),
      );

  final String userId;
  final String username;
  final String matrixUserId;
  final String? nickname;
  final String? remark;
  final String? avatarUrl;
  final String momentsPermission;
  final List<String> tags;

  String get displayName {
    for (final value in [remark, nickname, username]) {
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return username;
  }

  ContactSummary copyWith({String? remark, String? nickname}) => ContactSummary(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname ?? this.nickname,
        remark: remark ?? this.remark,
        avatarUrl: avatarUrl,
        momentsPermission: momentsPermission,
        tags: tags,
      );

  ContactDetails toDetails() => ContactDetails(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname,
        remark: remark,
        avatarUrl: avatarUrl,
        momentsPermission: momentsPermission,
        tags: tags,
      );
}

final class ContactDetails {
  const ContactDetails({
    required this.userId,
    required this.username,
    required this.matrixUserId,
    this.nickname,
    this.remark,
    this.avatarUrl,
    this.momentsPermission = 'DEFAULT',
    this.tags = const [],
  });

  final String userId;
  final String username;
  final String matrixUserId;
  final String? nickname;
  final String? remark;
  final String? avatarUrl;
  final String momentsPermission;
  final List<String> tags;

  String get displayName => ContactSummary(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname,
        remark: remark,
      ).displayName;

  ContactDetails copyWith({
    String? remark,
    List<String>? tags,
    String? momentsPermission,
  }) =>
      ContactDetails(
        userId: userId,
        username: username,
        matrixUserId: matrixUserId,
        nickname: nickname,
        remark: remark ?? this.remark,
        avatarUrl: avatarUrl,
        momentsPermission: momentsPermission ?? this.momentsPermission,
        tags: tags ?? this.tags,
      );
}

abstract interface class ContactsGateway {
  Future<List<ContactSummary>> listContacts();
  Future<ContactDetails> updateContactDetails(
    ContactDetails contact, {
    required String? remark,
    required List<String> tags,
    required String momentsPermission,
  });
  Future<void> blockContact(String userId);
  Future<void> deleteContact(String userId);
}
