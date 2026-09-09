import '../matrix/profile_repository.dart';
import 'dart:async';
import '../../core/business_api_client.dart';
import 'moment_models.dart';
import 'moments_privacy_changes.dart';

/// Scoped to the authenticated API instance; a route transition cannot start a
/// second write before its parent route's operation finishes.
final class PendingMomentReaction {
  final privacyRevision = momentsPrivacyChanges.revision;
  bool get audienceIsCurrent =>
      privacyRevision == momentsPrivacyChanges.revision;
  final _result = Completer<MomentItem>();
  Future<MomentItem> get result => _result.future;
  static final _writes = Expando<Map<String, PendingMomentReaction>>();
  static PendingMomentReaction? find(BusinessApiClient api, String id) =>
      _writes[api]?[id];
  static PendingMomentReaction begin(BusinessApiClient api, String id) {
    final writes = _writes[api] ??= {};
    return writes[id] = PendingMomentReaction();
  }

  void finish(BusinessApiClient api, MomentItem value) {
    if (identical(_writes[api]?[value.id], this)) {
      _writes[api]?.remove(value.id);
    }
    _result.complete(value);
  }
}

MomentAuthor momentViewer(ProfileRepository? identity,
    {String username = '', String userId = ''}) {
  final profile = identity?.profile;
  final name = profile?.username ?? username;
  return MomentAuthor(
    userId: userId,
    username: name,
    nickname: profile?.nickname ?? name,
    displayName: profile?.nickname ?? name,
    avatarUrl: profile?.avatarUrl,
  );
}

MomentItem toggleMomentReaction(MomentItem item, MomentAuthor viewer) {
  final users = item.likeUsers
      .where((person) => !((viewer.userId.isNotEmpty &&
              person.userId == viewer.userId) ||
          (viewer.username.isNotEmpty && person.username == viewer.username)))
      .toList();
  if (!item.liked) users.add(viewer);
  return item.copyWith(
    liked: !item.liked,
    likeCount: (item.likeCount + (item.liked ? -1 : 1)).clamp(0, 1 << 30),
    likeUsers: users,
  );
}

// Restore only the failed write's fields; comments may have changed meanwhile.
MomentItem restoreMomentReaction(MomentItem current, MomentItem before) =>
    current.copyWith(
        liked: before.liked,
        likeCount: before.likeCount,
        likeUsers: before.likeUsers);

/// Presentation projection only: never persist this subset over the server DTO.
/// With an unhydrated repository, fail closed for everyone except the viewer.
MomentItem visibleMomentReactions(MomentItem item, ProfileRepository? identity,
    {String username = ''}) {
  if (identity == null) return item;
  final own = identity.profile?.username ?? username;
  final visibleIds = identity.contacts
      .where((contact) => !const {
            'CHAT_ONLY',
            'ONLY_CHAT',
            'HIDE_BOTH',
            'HIDE_THEIRS'
          }.contains(contact.momentsPermission))
      .map((contact) => contact.userId)
      .toSet();
  bool visible(MomentAuthor person) =>
      (own.isNotEmpty && person.username == own) ||
      visibleIds.contains(person.userId);
  final likes = item.likeUsers.where(visible).toList();
  return item.copyWith(
      likeUsers: likes,
      likeCount: likes.length,
      comments: item.comments
          .where((comment) => visible(comment.author))
          .map((comment) {
        if (comment.parentAuthor == null || visible(comment.parentAuthor!)) {
          return comment;
        }
        return MomentCommentView(
            id: comment.id,
            text: comment.text,
            author: comment.author,
            createdAt: comment.createdAt,
            images: comment.images,
            imageCacheKeys: comment.imageCacheKeys);
      }).toList());
}
