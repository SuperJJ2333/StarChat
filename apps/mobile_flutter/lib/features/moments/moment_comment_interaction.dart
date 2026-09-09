import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../../core/business_api_client.dart';
import '../matrix/profile_repository.dart';
import 'moment_comment_composer.dart';
import 'moment_models.dart';
import 'moments_privacy_changes.dart';

/// Apply comment changes to the latest post, preserving concurrent reactions.
Future<void> interactWithMomentComment(
  BuildContext context, {
  required BusinessApiClient api,
  required String momentId,
  required String currentUsername,
  ProfileRepository? identityCache,
  MomentCommentView? comment,
  required MomentItem? Function() currentItem,
  required ValueChanged<MomentItem> onChanged,
  Future<void> Function(MomentItem)? onConfirmed,
  required ValueChanged<String?> onSelectionChanged,
  required ValueChanged<String> onError,
}) async {
  final privacyRevision = momentsPrivacyChanges.revision;
  bool active() =>
      context.mounted &&
      privacyRevision == momentsPrivacyChanges.revision &&
      currentItem() != null;
  if (!active()) return;
  final own = identityCache?.profile?.username ?? currentUsername;
  if (comment != null && own.isNotEmpty && comment.author.username == own) {
    final remove = await showCupertinoModalPopup<bool>(
        context: context,
        builder: (sheetContext) => CupertinoActionSheet(
                actions: [
                  CupertinoActionSheetAction(
                      onPressed: () {
                        Navigator.pop(sheetContext, false);
                        Clipboard.setData(ClipboardData(text: comment.text));
                      },
                      child: const Text('复制')),
                  CupertinoActionSheetAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(sheetContext, true),
                      child: const Text('删除')),
                ],
                cancelButton: CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(sheetContext, false),
                    child: const Text('取消'))));
    if (remove != true || !active()) return;
    try {
      await api.deleteMomentComment(momentId, comment.id);
      final current = currentItem();
      if (privacyRevision == momentsPrivacyChanges.revision &&
          current != null) {
        final updated = current.copyWith(
            comments:
                current.comments.where((c) => c.id != comment.id).toList());
        if (active()) onChanged(updated);
        await onConfirmed?.call(updated);
      }
    } catch (_) {
      if (active()) onError('删除失败，请重试');
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
