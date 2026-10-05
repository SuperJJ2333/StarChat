import 'dart:typed_data';
import '../../ui/foundation/avatar_cache.dart';
import 'notification_event.dart';

/// Auth headers stay in the local media request; only decoded display bytes
/// reach native presentation. Cache identities contain no bearer credentials.
Future<Uint8List?> loadNotificationAvatar(NotificationEvent event) async {
  final url = event.avatarUrl;
  if (url == null || url.isEmpty) return null;
  try {
    final key = AvatarCache.cacheKey(
        userId: event.avatarSeed ?? event.conversationId, avatarUrl: url);
    final cached = await AvatarCache.manager.getFileFromCache(key);
    final file = cached?.file ??
        await AvatarCache.manager
            .getSingleFile(url, key: key, headers: event.avatarHeaders);
    if (await file.length() > 512 * 1024) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}
