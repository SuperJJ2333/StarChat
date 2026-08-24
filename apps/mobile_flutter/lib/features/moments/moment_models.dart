final class MomentAuthor {
  const MomentAuthor(
      {required this.userId,
      required this.username,
      required this.nickname,
      this.remark,
      required this.displayName,
      this.avatarUrl});
  factory MomentAuthor.fromJson(Map<String, dynamic> json) => MomentAuthor(
      userId: json['user_id'].toString(),
      username: json['username']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      remark: json['remark']?.toString(),
      displayName: json['display_name']?.toString() ??
          json['remark']?.toString() ??
          json['nickname']?.toString() ??
          json['username']?.toString() ??
          '',
      avatarUrl: json['avatar_url']?.toString());
  final String userId, username, nickname, displayName;
  final String? remark;
  final String? avatarUrl;
}

final class MomentCommentView {
  const MomentCommentView({
    required this.id,
    required this.text,
    required this.author,
    this.parentAuthor,
  });

  factory MomentCommentView.fromJson(Map<String, dynamic> json) =>
      MomentCommentView(
        id: json['id'].toString(),
        text: json['text']?.toString() ?? '',
        author: MomentAuthor.fromJson(
            Map<String, dynamic>.from(json['author'] as Map)),
        parentAuthor: json['parent_author'] is Map
            ? MomentAuthor.fromJson(
                Map<String, dynamic>.from(json['parent_author'] as Map))
            : null,
      );

  final String id, text;
  final MomentAuthor author;
  final MomentAuthor? parentAuthor;
}

final class MomentItem {
  const MomentItem(
      {required this.id,
      required this.author,
      required this.text,
      required this.images,
      required this.createdAt,
      this.liked = false,
      this.likeCount = 0,
      this.remark,
      this.likeUsers = const [],
      this.comments = const [],
      this.kind = 'MOMENT',
      this.adLink});
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
              avatarUrl: ad['avatar_url']?.toString()),
          text: ad['text'].toString(),
          images: List<String>.from(ad['image_urls'] ?? const []),
          createdAt: DateTime.now(),
          kind: 'AD',
          adLink: ad['link_url']?.toString());
    }
    return MomentItem(
        id: json['id'].toString(),
        author: MomentAuthor.fromJson(
            Map<String, dynamic>.from(json['author'] as Map)),
        text: json['text']?.toString() ?? '',
        images: List<String>.from(json['image_urls'] ?? const []),
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
            DateTime.now(),
        liked: json['viewer_has_liked'] == true,
        likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
        remark: json['author']?['remark']?.toString(),
        likeUsers: (json['like_users'] as List? ?? const [])
            .map((v) =>
                MomentAuthor.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList(),
        comments: (json['comments'] as List? ?? const [])
            .map((v) =>
                MomentCommentView.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList());
  }
  final String id, text, kind;
  final MomentAuthor author;
  final List<String> images;
  final List<MomentAuthor> likeUsers;
  final List<MomentCommentView> comments;
  final DateTime createdAt;
  final bool liked;
  final int likeCount;
  final String? remark;
  final String? adLink;
  MomentItem copyWith({
    bool? liked,
    int? likeCount,
    List<MomentCommentView>? comments,
  }) =>
      MomentItem(
          id: id,
          author: author,
          text: text,
          images: images,
          createdAt: createdAt,
          liked: liked ?? this.liked,
          likeCount: likeCount ?? this.likeCount,
          remark: remark,
          likeUsers: likeUsers,
          comments: comments ?? this.comments,
          kind: kind,
          adLink: adLink);
}

String formatMomentTime(DateTime value, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(value);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays == 0) return '${diff.inHours}小时前';
  if (diff.inDays == 1) return '昨天';
  return '${value.month}月${value.day}日';
}
