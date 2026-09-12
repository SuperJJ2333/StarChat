import 'moment_visibility_selection.dart';

final class MomentAuthor {
  const MomentAuthor({
    required this.userId,
    required this.username,
    required this.nickname,
    required this.displayName,
    this.avatarUrl,
  });

  /// 备注隐私红线：作者展示只取服务端主昵称投影，绝不读取 remark 字段。
  factory MomentAuthor.fromJson(Map<String, dynamic> json) => MomentAuthor(
    userId: json['user_id'].toString(),
    username: json['username']?.toString() ?? '',
    nickname: json['nickname']?.toString() ?? '',
    displayName:
        json['display_name']?.toString() ??
        json['nickname']?.toString() ??
        json['username']?.toString() ??
        '',
    avatarUrl: json['avatar_url']?.toString(),
  );
  final String userId, username, nickname, displayName;
  final String? avatarUrl;
  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'username': username,
    'nickname': nickname,
    'display_name': displayName,
    'avatar_url': avatarUrl,
  };
}

final class MomentCommentView {
  const MomentCommentView({
    required this.id,
    required this.text,
    required this.author,
    this.parentAuthor,
    this.createdAt,
    this.images = const [],
    this.imageCacheKeys = const [],
  });

  factory MomentCommentView.fromJson(Map<String, dynamic> json) =>
      MomentCommentView(
        id: json['id'].toString(),
        text: json['text']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
        images: List<String>.from(json['image_urls'] ?? const []),
        imageCacheKeys: MomentItem._imageCacheKeys(json),
        author: MomentAuthor.fromJson(
          Map<String, dynamic>.from(json['author'] as Map),
        ),
        parentAuthor: json['parent_author'] is Map
            ? MomentAuthor.fromJson(
                Map<String, dynamic>.from(json['parent_author'] as Map),
              )
            : null,
      );

  final String id, text;
  final MomentAuthor author;
  final MomentAuthor? parentAuthor;
  final DateTime? createdAt;
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'created_at': createdAt?.toIso8601String(),
    'author': author.toJson(),
    'parent_author': parentAuthor?.toJson(),
    'image_urls': images,
    'image_cache_keys': imageCacheKeys,
  };
  final List<String> images;
  final List<String?> imageCacheKeys;
}

List<MomentCommentView> mergeMomentComments(
  Iterable<MomentCommentView> existing,
  MomentCommentView incoming,
) => <String, MomentCommentView>{
  for (final comment in existing) comment.id: comment,
  incoming.id: incoming,
}.values.toList(growable: false);

final class MomentItem {
  const MomentItem({
    required this.id,
    required this.author,
    required this.text,
    required this.images,
    required this.createdAt,
    this.imageCacheKeys = const [],
    this.liked = false,
    this.likeCount = 0,
    this.likeUsers = const [],
    this.comments = const [],
    this.kind = 'MOMENT',
    this.adLink,
    this.visibility,
    this.includeUserIds = const [],
    this.excludeUserIds = const [],
    this.includeTagIds = const [],
    this.excludeTagIds = const [],
  });
  /// 可见范围（作者本人视角由服务端返回；他人视角为 null/空）。
  final String? visibility;
  final List<String> includeUserIds;
  final List<String> excludeUserIds;
  final List<String> includeTagIds;
  final List<String> excludeTagIds;

  factory MomentItem.fromJson(Map<String, dynamic> json) {
    if (json['kind'] == 'AD') {
      final ad = Map<String, dynamic>.from(json['ad'] as Map);
      return MomentItem(
        id: json['id'].toString(),
        author: MomentAuthor(
          userId: 'ad',
          username: ad['advertiser_name'].toString(),
          nickname: ad['advertiser_name'].toString(),
          displayName: ad['advertiser_name'].toString(),
          avatarUrl: ad['avatar_url']?.toString(),
        ),
        text: ad['text'].toString(),
        images: List<String>.from(ad['image_urls'] ?? const []),
        imageCacheKeys: _imageCacheKeys(ad),
        createdAt: DateTime.now(),
        kind: 'AD',
        adLink: ad['link_url']?.toString(),
      );
    }
    return MomentItem(
      id: json['id'].toString(),
      author: MomentAuthor.fromJson(
        Map<String, dynamic>.from(json['author'] as Map),
      ),
      text: json['text']?.toString() ?? '',
      images: List<String>.from(json['image_urls'] ?? const []),
      imageCacheKeys: _imageCacheKeys(json),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      liked: json['viewer_has_liked'] == true,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      likeUsers: (json['like_users'] as List? ?? const [])
          .map(
            (v) => MomentAuthor.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList(),
      comments: (json['comments'] as List? ?? const [])
          .map(
            (v) =>
                MomentCommentView.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList(),
      visibility: json['visibility']?.toString(),
      includeUserIds: (json['include_user_ids'] as List? ?? const [])
          .map((v) => v.toString())
          .toList(growable: false),
      excludeUserIds: (json['exclude_user_ids'] as List? ?? const [])
          .map((v) => v.toString())
          .toList(growable: false),
      includeTagIds: (json['include_tag_ids'] as List? ?? const [])
          .map((v) => v.toString())
          .toList(growable: false),
      excludeTagIds: (json['exclude_tag_ids'] as List? ?? const [])
          .map((v) => v.toString())
          .toList(growable: false),
    );
  }
  final String id, text, kind;
  final MomentAuthor author;
  MomentVisibilitySelection? get visibilitySelection {
    final value = visibility;
    if (value == null) return null;
    return MomentVisibilitySelection(
      visibility: value,
      userIds: switch (value) {
        'INCLUDE' => Set.unmodifiable(includeUserIds),
        'EXCLUDE' => Set.unmodifiable(excludeUserIds),
        _ => const {},
      },
      tagIds: switch (value) {
        'INCLUDE' => Set.unmodifiable(includeTagIds),
        'EXCLUDE' => Set.unmodifiable(excludeTagIds),
        _ => const {},
      },
    );
  }

  MomentItem withVisibilitySelection(MomentVisibilitySelection selection) =>
      copyWith(
        visibility: selection.visibility,
        includeUserIds: selection.visibility == 'INCLUDE'
            ? selection.userIds.toList(growable: false)
            : const [],
        excludeUserIds: selection.visibility == 'EXCLUDE'
            ? selection.userIds.toList(growable: false)
            : const [],
        includeTagIds: selection.visibility == 'INCLUDE'
            ? selection.tagIds.toList(growable: false)
            : const [],
        excludeTagIds: selection.visibility == 'EXCLUDE'
            ? selection.tagIds.toList(growable: false)
            : const [],
      );

  static List<String?> _imageCacheKeys(Map<String, dynamic> json) {
    final keys = json['image_cache_keys'];
    final images = json['image_urls'];
    if (keys is! List || images is! List || keys.length != images.length) {
      return const [];
    }
    return keys.map((key) => key is String ? key : null).toList();
  }

  final List<String> images;
  final List<String?> imageCacheKeys;
  final List<MomentAuthor> likeUsers;
  final List<MomentCommentView> comments;
  final DateTime createdAt;
  final bool liked;
  final int likeCount;
  final String? adLink;
  MomentItem copyWith({
    bool? liked,
    int? likeCount,
    List<MomentAuthor>? likeUsers,
    List<MomentCommentView>? comments,
    String? visibility,
    List<String>? includeUserIds,
    List<String>? excludeUserIds,
    List<String>? includeTagIds,
    List<String>? excludeTagIds,
  }) => MomentItem(
    id: id,
    author: author,
    text: text,
    images: images,
    imageCacheKeys: imageCacheKeys,
    createdAt: createdAt,
    liked: liked ?? this.liked,
    likeCount: likeCount ?? this.likeCount,
    likeUsers: likeUsers ?? this.likeUsers,
    comments: comments ?? this.comments,
    kind: kind,
    adLink: adLink,
    visibility: visibility ?? this.visibility,
    includeUserIds: includeUserIds ?? this.includeUserIds,
    excludeUserIds: excludeUserIds ?? this.excludeUserIds,
    includeTagIds: includeTagIds ?? this.includeTagIds,
    excludeTagIds: excludeTagIds ?? this.excludeTagIds,
  );
}

String formatMomentTime(DateTime value, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(value);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays == 0) return '${diff.inHours}小时前';
  if (diff.inDays == 1) return '昨天';
  final local = value.toLocal();
  return '${local.month}月${local.day}日';
}
