import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import '../../ui/chat/group_avatar_mosaic.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'conversation_preferences.dart';
import 'matrix_user_avatar.dart';

/// A conversation avatar that also works before the full member list is cached.
final class MatrixConversationAvatar extends StatefulWidget {
  const MatrixConversationAvatar(
      {super.key, required this.room, this.size = 48});

  final Room room;
  final double size;

  @override
  State<MatrixConversationAvatar> createState() =>
      _MatrixConversationAvatarState();
}

final class _MatrixConversationAvatarState
    extends State<MatrixConversationAvatar> {
  List<User> members = const [];
  int generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MatrixConversationAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room != widget.room) _load();
  }

  void _load() {
    final room = widget.room;
    final current = ++generation;
    members = room.getParticipants([Membership.join]);
    if (room.isDirectChat || room.avatar != null) return;
    unawaited(() async {
      try {
        final loaded = await room.requestParticipants([Membership.join]);
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
    if (room.isDirectChat || room.avatar != null) {
      return MatrixUserAvatar(
        client: room.client,
        nickname: room.getLocalizedDisplayname(),
        fallbackSeed: room.id,
        matrixAvatarUri: room.avatar,
        size: widget.size,
      );
    }
    final byId = {for (final member in members) member.id: member};
    final orderedIds = reconcileMemberOrder(
      preferenceForRoom(room).memberOrderIds,
      byId.keys,
    ).take(9);
    if (orderedIds.isEmpty) {
      return SizedBox.square(
        dimension: widget.size,
        child: const ColoredBox(
          color: WeChatColors.lightSurface,
          child: Icon(CupertinoIcons.person_2_fill, size: 25),
        ),
      );
    }
    return GroupAvatarMosaic(
      size: widget.size,
      avatars: [
        for (final id in orderedIds)
          MatrixUserAvatar(
            client: room.client,
            nickname: byId[id]!.calcDisplayname(),
            fallbackSeed: id,
            matrixAvatarUri: byId[id]!.avatarUrl,
            size: widget.size,
          ),
      ],
    );
  }
}
