import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'matrix_e2ee_client.dart';

import '../../ui/chat/group_avatar_mosaic.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'conversation_preferences.dart';
import 'matrix_user_avatar.dart';

/// A conversation avatar that also works before the full member list is cached.
final class MatrixConversationAvatar extends StatefulWidget {
  const MatrixConversationAvatar(
      {super.key,
      required this.room,
      required this.avatarMedia,
      this.loadMembers,
      this.size = 48});

  final MatrixConversationRoomSnapshot room;
  final AvatarMediaCapability avatarMedia;
  final Future<List<MatrixMemberSnapshot>> Function()? loadMembers;
  final double size;

  @override
  State<MatrixConversationAvatar> createState() =>
      _MatrixConversationAvatarState();
}

final class _MatrixConversationAvatarState
    extends State<MatrixConversationAvatar> {
  List<MatrixMemberSnapshot> members = const [];
  int generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MatrixConversationAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room != widget.room ||
        oldWidget.loadMembers != widget.loadMembers) {
      _load();
    }
  }

  void _load() {
    final room = widget.room;
    final current = ++generation;
    members = room.members;
    if (room.isDirect || room.avatar != null || widget.loadMembers == null) {
      return;
    }
    unawaited(() async {
      try {
        final loaded = await widget.loadMembers!();
        if (!mounted || generation != current) return;
        setState(() => members = loaded);
      } catch (_) {
        // Keep cached avatars, or the visible group fallback while offline.
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    if (room.isDirect || room.avatar != null) {
      return MatrixUserAvatar(
        avatarMedia: widget.avatarMedia,
        nickname: room.displayName,
        fallbackSeed: room.id,
        matrixAvatarUri: room.avatar,
        size: widget.size,
      );
    }
    final byId = {for (final member in members) member.id: member};
    final orderedIds = reconcileMemberOrder(
      room.preference.memberOrderIds,
      byId.keys,
    ).take(9);
    if (orderedIds.isEmpty) {
      return SizedBox.square(
        dimension: widget.size,
        child: ColoredBox(
          color: WeChatColors.resolve(context, WeChatColors.lightSurface),
          child: Icon(CupertinoIcons.person_2_fill, size: 25),
        ),
      );
    }
    return GroupAvatarMosaic(
      size: widget.size,
      avatars: [
        for (final id in orderedIds)
          MatrixUserAvatar(
            avatarMedia: widget.avatarMedia,
            nickname: byId[id]!.displayName,
            fallbackSeed: id,
            matrixAvatarUri: byId[id]!.avatar,
            size: widget.size,
          ),
      ],
    );
  }
}
