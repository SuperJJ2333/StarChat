import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../../core/business_api_client.dart';
import '../../core/cache/cache_repository.dart';
import '../matrix/profile_repository.dart';
import 'moment_comment_composer.dart';
import 'moment_models.dart';
import '../../ui/components/anchored_action_menu.dart';

import 'moments_privacy_changes.dart';

final momentCommentDeletions = ValueNotifier<ConfirmedCommentDeletion?>(null);

final class ConfirmedCommentDeletion {
  const ConfirmedCommentDeletion(
      this.api, this.username, this.momentId, this.commentId);
  final BusinessApiClient api;
  final String username, momentId, commentId;
  bool appliesTo(BusinessApiClient candidate, String viewer) =>
      identical(api, candidate) && username == viewer;
  MomentItem apply(MomentItem item) => item.id != momentId
      ? item
      : item.copyWith(
          comments: item.comments.where((c) => c.id != commentId).toList());
}

final _pendingCommentDeletes = Expando<Set<String>>();
final _commentMenus = Expando<bool>();

/// Apply comment changes to the latest post, preserving concurrent reactions.
Future<void> interactWithMomentComment(
  BuildContext context, {
  required BusinessApiClient api,
  required String momentId,
  required String currentUsername,
  ProfileRepository? identityCache,
  MomentCommentView? comment,
  bool longPress = false,
  Rect? anchor,
  required MomentItem? Function() currentItem,
  required ValueChanged<MomentItem> onChanged,
  Future<void> Function(MomentItem)? onConfirmed,
  required ValueChanged<String?> onSelectionChanged,
  required ValueChanged<String> onError,
}) async {
  final account = identityCache?.profile?.username ?? currentUsername;
  final privacyRevision = momentsPrivacyChanges.revision;
  bool audienceCurrent() =>
      (identityCache?.profile?.username ?? currentUsername) == account &&
      privacyRevision == momentsPrivacyChanges.revision &&
      currentItem() != null;
  bool active() => context.mounted && audienceCurrent();
  if (!active()) return;
  final own = identityCache?.profile?.username ?? currentUsername;
  final ownComment =
      comment != null && own.isNotEmpty && comment.author.username == own;
  if (ownComment && !longPress) return;
  if (comment != null && longPress) {
    final canDelete = own.isNotEmpty &&
        (comment.author.username == own ||
            currentItem()?.author.username == own);
    final navigator = Navigator.of(context, rootNavigator: true);
    if (_commentMenus[navigator] == true) return;
    _commentMenus[navigator] = true;
    String? selected;
    try {
      selected = await showAnchoredActionMenu<String>(context,
          anchor: anchor,
          items: [
            const AnchoredMenuItem(
                value: 'copy', icon: CupertinoIcons.doc_on_doc, label: '复制'),
            if (canDelete)
              const AnchoredMenuItem(
                  value: 'delete', icon: CupertinoIcons.trash, label: '删除'),
          ]);
    } finally {
      _commentMenus[navigator] = false;
    }
    if (!active()) return;
    if (selected == 'copy') {
      await Clipboard.setData(ClipboardData(text: comment.text));
      return;
    }
    if (selected != 'delete' || !canDelete) return;
    final pending = _pendingCommentDeletes[api] ??= <String>{};
    final pendingKey = '$account/$momentId/${comment.id}';
    if (!pending.add(pendingKey)) return;
    var serverConfirmed = false;
    var persistenceFailed = false;
    try {
      await api.deleteMomentComment(momentId, comment.id);
      serverConfirmed = true;
      final current = currentItem();
      if (audienceCurrent() && current != null) {
        final updated = current.copyWith(
            comments:
                current.comments.where((c) => c.id != comment.id).toList());
        final deletion =
            ConfirmedCommentDeletion(api, own, momentId, comment.id);
        momentCommentDeletions.value = deletion;
        if (active()) onChanged(updated);
        try {
          await onConfirmed?.call(updated);
        } catch (_) {
          persistenceFailed = true;
        }
        if (!audienceCurrent()) return;
        final accountKey = identityCache?.accountKey;
        if (accountKey != null) {
          final repository = await CacheRepository.instance();
          if (!audienceCurrent()) return;
          final cache = repository.momentsFor(accountKey);
          final snapshot = cache.snapshot;
          if (snapshot != null) {
            cache.beginRefresh();
            await cache.save({
              ...snapshot,
              'items': [
                for (final raw in snapshot['items'] as List? ?? [])
                  if (raw is Map && raw['id'] == momentId)
                    {
                      ...raw,
                      'comments': [
                        for (final c in raw['comments'] as List? ?? [])
                          if (c is! Map || c['id'] != comment.id) c
                      ]
                    }
                  else
                    raw
              ]
            });
          }
        }
        if (persistenceFailed && active()) {
          onError('评论已删除，请刷新页面');
        }
      }
    } catch (_) {
      if (active()) {
        onError(serverConfirmed ? '评论已删除，请刷新页面' : '删除失败，请重试');
      }
    } finally {
      pending.remove(pendingKey);
    }
    return;
  }
  onSelectionChanged(comment?.id);
  try {
    final result = await showMomentCommentComposer(context,
        api: api,
        momentId: momentId,
        identityCache: identityCache,
        parent: comment);
    if (result != null && active()) {
      final current = currentItem()!;
      final updated = current.copyWith(
          comments: mergeMomentComments(current.comments, result));
      onChanged(updated);
      await onConfirmed?.call(updated);
    }
  } finally {
    if (context.mounted) onSelectionChanged(null);
  }
}
