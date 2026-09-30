import 'package:flutter/cupertino.dart';

import '../../ui/chat/group_avatar_mosaic.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../matrix/matrix_user_avatar.dart';
import '../matrix/profile_repository.dart';
import 'global_search_models.dart';

/// Paints a search result from the current room snapshot and local identity.
/// Mutable avatar URLs are never copied into the message-search index.
final class SearchRoomAvatar extends StatelessWidget {
  const SearchRoomAvatar({
    super.key,
    required this.room,
    this.avatarMedia,
    this.identityCache,
    this.size = WeChatDimensions.contactAvatar,
  });

  final GlobalSearchRoomResult room;
  final AvatarMediaCapability? avatarMedia;
  final ProfileRepository? identityCache;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: identityCache == null
            ? _avatar()
            : ListenableBuilder(
                listenable: identityCache!,
                builder: (context, _) => _avatar(),
              ),
      );

  Widget _avatar() {
    if (room.isDirect) {
      return _personAvatar(
        matrixUserId: room.directPeerId,
        displayName: room.displayName,
        matrixAvatarUri: room.matrixAvatarUri,
        fallbackAvatarUrl: room.avatarUrl,
        fallbackSeed: room.avatarSeed ?? room.roomId,
      );
    }

    if (room.matrixAvatarUri != null && avatarMedia != null) {
      return MatrixUserAvatar(
        avatarMedia: avatarMedia!,
        nickname: room.displayName,
        fallbackSeed: room.avatarSeed ?? room.roomId,
        matrixAvatarUri: room.matrixAvatarUri,
        fallbackAvatarUrl: room.avatarUrl,
        size: size,
      );
    }

    if (room.matrixAvatarUri == null && room.avatarMembers.isNotEmpty) {
      return GroupAvatarMosaic(
        size: size,
        avatars: [
          for (final member in room.avatarMembers.take(9))
            _personAvatar(
              matrixUserId: member.userId,
              displayName: member.displayName,
              matrixAvatarUri: member.matrixAvatarUri,
              fallbackSeed: member.userId,
            ),
        ],
      );
    }

    return UserAvatar(
      nickname: room.displayName,
      fallbackSeed: room.avatarSeed ?? room.roomId,
      avatarUrl: room.avatarUrl,
      size: size,
    );
  }

  Widget _personAvatar({
    required String? matrixUserId,
    required String displayName,
    required Uri? matrixAvatarUri,
    required String fallbackSeed,
    String? fallbackAvatarUrl,
  }) {
    final identity = matrixUserId == null || matrixUserId.trim().isEmpty
        ? null
        : identityCache?.resolveIdentity(
            matrixUserId: matrixUserId,
            displayName: displayName,
          );
    final name = identity?.displayName ?? displayName;
    final seed = identity?.cacheKey ?? matrixUserId ?? fallbackSeed;
    final uri = identity?.avatarIsKnown == true ? null : matrixAvatarUri;
    final url = identity?.avatarIsKnown == true
        ? identity?.avatarUrl
        : identity?.avatarUrl ?? fallbackAvatarUrl;
    final media = avatarMedia;
    if (media != null && (room.isDirect || uri != null)) {
      return MatrixUserAvatar(
        avatarMedia: media,
        nickname: name,
        fallbackSeed: seed,
        matrixAvatarUri: uri,
        fallbackAvatarUrl: url,
        size: size,
      );
    }
    return UserAvatar(
      nickname: name,
      fallbackSeed: seed,
      avatarUrl: url,
      size: size,
    );
  }
}
