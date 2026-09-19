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

final class ApiDirectRoomCoordinator
    implements DirectRoomCoordinator, DirectRoomLifecycleCoordinator {
  ApiDirectRoomCoordinator(this.api);
  final BusinessApiClient api;
  final Map<String, (int, String?)> _revisions = {};
  int? _epoch;

  @override
  Future<void> offerExistingRoom(String peer, String roomId) =>
      api.registerDirectConversationHistory(peer, roomId);

  void _accept(String peer, int epoch, int revision, String? room) {
    if (epoch != api.sessionEpoch) {
      throw StateError('Direct conversation account changed');
    }
    if (_epoch != epoch) {
      _revisions.clear();
      _epoch = epoch;
    }
    final previous = _revisions[peer];
    if (previous != null &&
        (revision < previous.$1 ||
            (revision == previous.$1 &&
                room != null &&
                previous.$2 != null &&
                room != previous.$2))) {
      throw StateError('Stale direct conversation resolution');
    }
    _revisions[peer] = (revision, room ?? previous?.$2);
  }

  @override
  Future<DirectRoomResolution> resolve(String peer, String attemptId) async {
    final epoch = api.sessionEpoch;
    final body = await api.postJson('/direct-conversations/resolve',
        {'peer_user_id': peer, 'attempt_id': attemptId},
        idempotencyKey: attemptId);
    final status = body['status'];
    final generation = body['generation'];
    final revision = body['revision'];
    final room = body['matrix_room_id'];
    final rooms = body['room_ids'];
    final alias = body['room_alias_localpart'];
    final reservation = body['reservation_id'];
    if (!['ready', 'join_required', 'create_required', 'unavailable']
            .contains(status) ||
        generation is! int ||
        generation < 0 ||
        revision is! int ||
        revision < 0 ||
        rooms is! List ||
        rooms.any((id) => id is! String || id.isEmpty) ||
        (room != null && (room is! String || room.isEmpty)) ||
        ((status == 'ready' || status == 'join_required') && room == null) ||
        (status == 'create_required' &&
            (room != null ||
                alias is! String ||
                !RegExp(r'^chatflow_dm_[a-f0-9]{32}$').hasMatch(alias) ||
                reservation is! String ||
                reservation.isEmpty))) {
      throw StateError('Invalid direct conversation recovery response');
    }
    _accept(peer, epoch, revision, room as String?);
    api.acceptDirectConversationSnapshot(peer, body, epoch: epoch);
    return DirectRoomResolution(
        status: status as String,
        generation: generation,
        revision: revision,
        roomIds: List<String>.unmodifiable(rooms.cast<String>()),
        roomId: room,
        alias: alias as String?,
        reservationId: reservation as String?);
  }

  @override
  Future<DirectRoomResolution> publishRecovery(String peer, String attemptId,
      DirectRoomResolution resolution, String roomId) async {
    final epoch = api.sessionEpoch;
    final body = await api.postJson(
        '/direct-conversations/publish-recovery',
        {
          'peer_user_id': peer,
          'attempt_id': attemptId,
          'generation': resolution.generation,
          'reservation_id': resolution.reservationId,
          'matrix_room_id': roomId,
        },
        idempotencyKey: attemptId);
    final room = body['matrix_room_id'];
    final revision = body['revision'];
    if (room is! String ||
        room.isEmpty ||
        body['generation'] != resolution.generation ||
        revision is! int ||
        revision < resolution.revision) {
      throw StateError('Invalid direct conversation publication response');
    }
    _accept(peer, epoch, revision, room);
    api.acceptDirectConversationSnapshot(peer, body, epoch: epoch);
    return DirectRoomResolution(
        status: 'ready',
        generation: resolution.generation,
        revision: revision,
        roomId: room,
        roomIds: {...resolution.roomIds, room}.toList());
  }

  @override
  Future<String?> canonicalRoomId(String peer) =>
      api.canonicalDirectRoomId(peer);

  @override
  Future<DirectRoomClaim> claim(String peer, String attemptId) async {
    final body = await api.claimRecoverableDirectConversation(peer, attemptId);
    final roomId = body['matrix_room_id'];
    if (roomId != null && (roomId is! String || roomId.isEmpty)) {
      throw StateError('Invalid canonical room response');
    }
    if (body['may_create'] is! bool || body['can_publish'] is! bool) {
      throw StateError('Direct-room coordination is unavailable');
    }
    if (roomId == null &&
        body['may_create'] == true &&
        (body['room_alias_localpart'] is! String ||
            body['reservation_id'] is! String ||
            !RegExp(r'^chatflow_dm_[a-f0-9]{32}$')
                .hasMatch(body['room_alias_localpart'] as String) ||
            (body['reservation_id'] as String).isEmpty)) {
      throw StateError('Recoverable coordination evidence is incomplete');
    }
    return DirectRoomClaim(
      roomId: roomId as String?,
      roomAliasLocalpart: body['room_alias_localpart'] as String?,
      reservationId: body['reservation_id'] as String?,
      mayCreate: body['may_create'] == true,
      canPublish: body['can_publish'] == true,
    );
  }

  @override
  Future<String> publish(String peer, String attemptId, String roomId) =>
      api.recoverDirectConversation(peer, attemptId, roomId);
}
