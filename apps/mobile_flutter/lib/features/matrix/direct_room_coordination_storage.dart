import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/business_api_client.dart';
import 'coordinated_direct_chat.dart';

/// Account-scoped creation intent; contains only identifiers, never room keys.
/// Fail closed if durable persistence is unavailable before requesting a grant.
final class PreferencesDirectRoomIntentStore implements DirectRoomIntentStore {
  PreferencesDirectRoomIntentStore(this.accountId);
  final String accountId;
  String _key(String peer) {
    if (accountId.isEmpty) throw StateError('Account identity is unavailable');
    return 'direct-room-intent-v1:${Uri.encodeComponent(accountId)}:'
        '${Uri.encodeComponent(peer)}';
  }

  @override
  Future<DirectRoomIntent> loadOrCreate(String peer) async {
    final preferences = await SharedPreferences.getInstance();
    final key = _key(peer);
    final raw = preferences.getString(key);
    if (raw != null) {
      final value = jsonDecode(raw) as Map<String, dynamic>;
      final attempt = value['attempt_id'];
      if (attempt is! String || attempt.isEmpty) {
        throw StateError('Invalid persisted direct-room intent');
      }
      return DirectRoomIntent(
          attemptId: attempt, roomId: value['room_id'] as String?);
    }
    final intent = DirectRoomIntent(attemptId: const Uuid().v4());
    if (!await preferences.setString(
        key,
        jsonEncode({
          'attempt_id': intent.attemptId,
        }))) {
      throw StateError('Could not persist direct-room intent');
    }
    return intent;
  }

  @override
  Future<void> saveRoom(
      String peer, DirectRoomIntent intent, String roomId) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(
        _key(peer),
        jsonEncode({
          'attempt_id': intent.attemptId,
          'room_id': roomId,
        }))) {
      throw StateError('Could not persist direct-room result');
    }
  }
}

final class ApiDirectRoomCoordinator implements DirectRoomCoordinator {
  ApiDirectRoomCoordinator(this.api);
  final BusinessApiClient api;

  @override
  Future<String?> canonicalRoomId(String peer) =>
      api.canonicalDirectRoomId(peer);

  @override
  Future<DirectRoomClaim> claim(String peer, String attemptId) async {
    final body = await api.claimDirectConversation(peer, attemptId);
    final roomId = body['matrix_room_id'];
    if (roomId != null && (roomId is! String || roomId.isEmpty)) {
      throw StateError('Invalid canonical room response');
    }
    if (body['may_create'] is! bool || body['can_publish'] is! bool) {
      throw StateError('Direct-room coordination is unavailable');
    }
    return DirectRoomClaim(
      roomId: roomId as String?,
      mayCreate: body['may_create'] == true,
      canPublish: body['can_publish'] == true,
    );
  }

  @override
  Future<String> publish(String peer, String attemptId, String roomId) =>
      api.publishDirectConversation(peer, attemptId, roomId);
}
