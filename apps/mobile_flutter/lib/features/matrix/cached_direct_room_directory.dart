import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'direct_chat_controller.dart';

/// Only caches IDs returned by the authoritative business directory. Opening
/// still revalidates Matrix membership/encryption; never cache a room snapshot.
final class CachedDirectRoomDirectory implements CanonicalDirectRoomDirectory {
  CachedDirectRoomDirectory({required this.accountId, required this.upstream});
  final String accountId;
  final CanonicalDirectRoomDirectory upstream;
  final _refreshing = <String, Future<String?>>{};
  final _versions = <String, int>{};
  String _key(String peer) =>
      'canonical-room-v1:${Uri.encodeComponent(accountId)}:${Uri.encodeComponent(peer)}';

  Future<String?> _refresh(String peer, SharedPreferences preferences) =>
      _refreshing.putIfAbsent(peer, () async {
        final version = _versions[peer] ?? 0;
        try {
          final id = await upstream.canonicalRoomId(peer);
          if ((_versions[peer] ?? 0) != version) return id;
          if (id == null || id.isEmpty) {
            await preferences.remove(_key(peer));
          } else {
            await preferences.setString(_key(peer), id);
          }
          return id;
        } finally {
          _refreshing.remove(peer);
        }
      });

  @override
  Future<String?> canonicalRoomId(String peerUserId) async {
    if (accountId.isEmpty) return upstream.canonicalRoomId(peerUserId);
    SharedPreferences preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } catch (_) {
      return upstream.canonicalRoomId(peerUserId);
    }
    final cached = preferences.getString(_key(peerUserId));
    final refresh = _refresh(peerUserId, preferences);
    if (cached != null && cached.isNotEmpty) {
      unawaited(
          refresh.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      return cached;
    }
    return refresh;
  }

  @override
  Future<String?> registerRoom(String peerUserId, String roomId) async {
    // Supersede an older lookup without blocking entry on its network request.
    _versions[peerUserId] = (_versions[peerUserId] ?? 0) + 1;
    final effective = await upstream.registerRoom(peerUserId, roomId);
    if (accountId.isNotEmpty && effective != null && effective.isNotEmpty) {
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(_key(peerUserId), effective);
      } catch (_) {/* Storage failure cannot block a valid room. */}
    }
    return effective;
  }
}
