/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:matrix/encryption/utils/olm_session.dart';
import 'package:matrix/encryption/utils/outbound_group_session.dart';
import 'package:matrix/encryption/utils/ssss_cache.dart';
import 'package:matrix/encryption/utils/stored_inbound_group_session.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/queued_to_device_event.dart';

/// A page is acknowledged only after its payload has been successfully loaded.
class TimelineIdPage {
  TimelineIdPage(this.ids,
      {required this.hasMore, required this.cursor, int? rawCount})
      : rawCount = rawCount ?? ids.length;
  final List<String> ids;

  /// Indexed rows examined, including rows invisible at the captured revision.
  final int rawCount;
  final bool hasMore;
  final int cursor;
}

class TimelineStorageClosed extends StateError {
  TimelineStorageClosed() : super('Timeline database closed');
}

class TimelineSnapshotDisposed extends StateError {
  TimelineSnapshotDisposed() : super('Timeline snapshot disposed');
}

class TimelineAnchorUnavailable implements Exception {
  const TimelineAnchorUnavailable();
}

enum TimelineIdDirection { older, newer }

abstract class TimelineIdSnapshot {
  /// Captured fragment count, or -1 while legacy coverage is incomplete.
  /// Only page.hasMore determines cursor exhaustion.
  int get length;
  Future<TimelineIdPage> next({int limit = 30});
  Future<TimelineIdSnapshot> checkpoint();
  Future<TimelineIdSnapshot> fork(
      {required String afterEventId,
      TimelineIdDirection direction = TimelineIdDirection.older});
  void accept(TimelineIdPage page);
  void dispose();
}

extension TimelineIdSnapshotCoverage on TimelineIdSnapshot {
  /// Unknown coverage is distinct from an empty fragment. Page.hasMore remains
  /// authoritative; callers needing an exact count use the maintenance API.
  int? get exactLength => length < 0 ? null : length;
}

class TimelineLegacyPage {
  TimelineLegacyPage(this.ids,
      {required this.start, required this.hasMore, this.positions = const {}});
  final List<String> ids;
  final int start;
  final bool hasMore;
  final Map<String, int> positions;
}

/// Independent foreground BLOB access. Seeking a historical anchor may scan
/// old bytes in a worker, but never holds the collection transaction gate.
typedef TimelineLegacyPageReader = Future<TimelineLegacyPage> Function(
    String fragment, String sourceIdentity,
    {int start,
    int limit,
    List<String>? findEventIds,
    bool reverse,
    bool Function()? isCancelled});

class ListTimelineIdSnapshot implements TimelineIdSnapshot {
  ListTimelineIdSnapshot(List<String> ids,
      {String? afterEventId, this.direction = TimelineIdDirection.older})
      : _ids = List.unmodifiable(ids) {
    final index = afterEventId == null ? null : ids.indexOf(afterEventId);
    if (index == -1) throw const TimelineAnchorUnavailable();
    _cursor = direction == TimelineIdDirection.older
        ? (index ?? -1) + 1
        : (index ?? ids.length) - 1;
  }
  List<String>? _ids;
  final TimelineIdDirection direction;
  late int _cursor;
  TimelineIdPage? _pending;
  @override
  int get length => _ids?.length ?? 0;
  @override
  Future<TimelineIdPage> next({int limit = 30}) async {
    if (limit < 1 || limit > 256) throw RangeError.range(limit, 1, 256);
    final ids = _ids;
    if (ids == null) throw TimelineSnapshotDisposed();
    if (_pending != null) return _pending!;
    final result = <String>[];
    var index = _cursor;
    final step = direction == TimelineIdDirection.older ? 1 : -1;
    while (result.length < limit && index >= 0 && index < ids.length) {
      result.add(ids[index]);
      index += step;
    }
    return _pending = TimelineIdPage(List.unmodifiable(result),
        hasMore: index >= 0 && index < ids.length, cursor: index);
  }

  @override
  Future<TimelineIdSnapshot> checkpoint() async {
    final ids = _ids;
    if (ids == null) throw TimelineSnapshotDisposed();
    return ListTimelineIdSnapshot(ids, direction: direction).._cursor = _cursor;
  }

  @override
  Future<TimelineIdSnapshot> fork(
      {required String afterEventId,
      TimelineIdDirection direction = TimelineIdDirection.older}) async {
    final ids = _ids;
    if (ids == null) throw TimelineSnapshotDisposed();
    return ListTimelineIdSnapshot(ids,
        afterEventId: afterEventId, direction: direction);
  }

  @override
  void accept(TimelineIdPage page) {
    if (_ids == null || !identical(page, _pending)) {
      throw StateError('Invalid timeline page');
    }
    _cursor = page.cursor;
    _pending = null;
  }

  @override
  void dispose() {
    _ids = null;
    _pending = null;
  }
}

/// The reader must retain the encrypted account identity and execute source
/// decoding off the UI isolate. Each emitted page is at most 256 IDs.
/// Search metadata only: encrypted bodies never cross the migration worker.
class TimelineSearchEntry {
  const TimelineSearchEntry(this.eventId, this.originServerTs,
      {this.isSent = true});
  final String eventId;
  final int? originServerTs;
  final bool isSent;
}

typedef TimelineSearchMigrationReader = Stream<List<TimelineSearchEntry>>
    Function(String roomId, String? afterEventId);

typedef TimelineMigrationReader = Stream<List<String>> Function(
    String fragmentKey);

abstract class DatabaseApi {
  Future<void> prepareTimelineStorage(Iterable<String> roomIds) async {}

  /// Foreground authority preflight. Incremental backends need not finish
  /// canonical migration; existing backends retain their preparation behavior.
  Future<void> prepareTimelineAuthority(Iterable<String> roomIds,
          {Iterable<String> eventIds = const []}) =>
      prepareTimelineStorage(roomIds);

  /// Preflight only the ordering metadata that this response can mutate.
  /// Backends without an incremental store retain their existing behavior.
  Future<void> prepareSyncTimelineStorage(
          SyncUpdate sync, Iterable<String> pendingDecryptionRooms) =>
      prepareTimelineStorage({
        ...?sync.rooms?.join?.keys,
        ...?sync.rooms?.leave?.keys,
        ...?sync.rooms?.invite?.keys,
        ...pendingDecryptionRooms,
      });

  Future<TimelineIdSnapshot> openTimelineIdSnapshot(Room room,
      {String? afterEventId,
      bool includeSending = false,
      TimelineIdDirection direction = TimelineIdDirection.older}) async {
    final ids = await getEventIdList(room, includeSending: includeSending);
    return ListTimelineIdSnapshot(ids,
        afterEventId: afterEventId, direction: direction);
  }

  Future<Map<String, int>> getTimelineEventPositions(
      Room room, Iterable<String> ids) async {
    final requested = ids.toSet();
    if (requested.length > 256) {
      throw RangeError('Maximum 256 timeline positions');
    }
    final all = await getEventIdList(room);
    return {
      for (final id in requested)
        if (all.contains(id)) id: all.indexOf(id)
    };
  }

  Future<int> getTimelineEventCount(Room room) async =>
      (await getEventIdList(room)).length;

  int get maxFileSize => 1 * 1024 * 1024;

  bool get supportsFileStoring => false;

  Future<Map<String, dynamic>?> getClient(String name);

  Future updateClient(
    String homeserverUrl,
    String token,
    DateTime? tokenExpiresAt,
    String? refreshToken,
    String userId,
    String? deviceId,
    String? deviceName,
    String? prevBatch,
    String? olmAccount,
  );

  Future insertClient(
    String name,
    String homeserverUrl,
    String token,
    DateTime? tokenExpiresAt,
    String? refreshToken,
    String userId,
    String? deviceId,
    String? deviceName,
    String? prevBatch,
    String? olmAccount,
  );

  Future<List<Room>> getRoomList(Client client);

  /// Restore required local room metadata without optional history repair.
  Future<List<Room>> getCachedRoomList(Client client) => getRoomList(client);

  /// Optional local preview repair after the cached room list is published.
  Future<void> refreshRoomListPreviews(List<Room> rooms, Client client,
      {bool Function()? isCurrent}) async {}

  Future<Room?> getSingleRoom(Client client, String roomId,
      {bool loadImportantStates = true});

  Future<Map<String, BasicEvent>> getAccountData();

  /// Stores a RoomUpdate object in the database. Must be called inside of
  /// [transaction].
  Future<void> storeRoomUpdate(
    String roomId,
    SyncRoomUpdate roomUpdate,
    Event? lastEvent,
    Client client,
  );

  Future<void> deleteTimelineForRoom(String roomId);

  /// Stores an EventUpdate object in the database. Must be called inside of
  /// [transaction].
  Future<void> storeEventUpdate(EventUpdate eventUpdate, Client client);

  Future<Event?> getEventById(String eventId, Room room);

  Future<void> forgetRoom(String roomId);

  Future<CachedProfileInformation?> getUserProfile(String userId);

  Future<void> storeUserProfile(
      String userId, CachedProfileInformation profile);

  Future<void> markUserProfileAsOutdated(String userId);

  Future<void> clearCache();

  Future<void> clear();

  Future<User?> getUser(String userId, Room room);

  Future<List<User>> getUsers(Room room);

  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  });

  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    bool includeSending = false,
    int? limit,
  });

  Future<Uint8List?> getFile(Uri mxcUri);

  Future storeFile(Uri mxcUri, Uint8List bytes, int time);

  Future storeSyncFilterId(
    String syncFilterId,
  );

  Future storeAccountData(String type, String content);

  Future<Map<String, DeviceKeysList>> getUserDeviceKeys(Client client);

  Future<SSSSCache?> getSSSSCache(String type);

  Future<OutboundGroupSession?> getOutboundGroupSession(
    String roomId,
    String userId,
  );

  Future<List<StoredInboundGroupSession>> getAllInboundGroupSessions();

  Future<List<StoredInboundGroupSession>> getInboundGroupSessionsPage(
          {String? afterSessionId, int limit = 80}) =>
      throw UnsupportedError('Bounded session export unavailable');

  Future<Map<String, dynamic>?> getRecoveryCheckpoint(String key) =>
      throw UnsupportedError('Recovery checkpoints unavailable');

  Future<void> storeRecoveryRecord(String key, Map<String, dynamic> value) =>
      throw UnsupportedError('Recovery records unavailable');

  Future<int> recoveryProtectedCount(String version) =>
      throw UnsupportedError('Recovery receipt counts unavailable');

  /// Keyset page of undecrypted ciphertext within the admitted history window.
  Future<List<String>> getRecoveryPendingEventIds(Room room,
          {required int windowStart,
          required int windowEnd,
          String? afterEventId,
          int limit = 80}) =>
      throw UnsupportedError('Recovery replay requires SQLite');

  Future<List<String>> getRecoveryEventIds(Room room,
          {int start = 0, int limit = 80}) =>
      throw UnsupportedError('Bounded recovery replay unavailable');

  Future<bool> hasRecoveryCursor(String key, String cursor) =>
      throw UnsupportedError('Recovery cursors unavailable');

  Future<void> storeRecoveryDecryptedEvent(Event event) =>
      throw UnsupportedError('Recovery projection unavailable');

  Future<({int downloaded, int decrypted, int missing})> recoveryRoomCounts(
          Room room, int windowStart, int windowEnd) =>
      throw UnsupportedError('Recovery counts unavailable');

  Future<bool> commitRecoveryHistoryPage(
          Room room,
          String key,
          int expectedRevision,
          List<Map<String, dynamic>> events,
          Map<String, dynamic> checkpoint) =>
      throw UnsupportedError('Independent history unavailable');

  Future<StoredInboundGroupSession?> getInboundGroupSession(
    String roomId,
    String sessionId,
  );

  Future updateInboundGroupSessionIndexes(
    String indexes,
    String roomId,
    String sessionId,
  );

  Future storeInboundGroupSession(
    String roomId,
    String sessionId,
    String pickle,
    String content,
    String indexes,
    String allowedAtIndex,
    String senderKey,
    String senderClaimedKey,
  );

  Future markInboundGroupSessionAsUploaded(
    String roomId,
    String sessionId,
  );

  Future updateInboundGroupSessionAllowedAtIndex(
    String allowedAtIndex,
    String roomId,
    String sessionId,
  );

  Future removeOutboundGroupSession(String roomId);

  Future storeOutboundGroupSession(
    String roomId,
    String pickle,
    String deviceIds,
    int creationTime,
  );

  Future updateClientKeys(
    String olmAccount,
  );

  Future storeOlmSession(
    String identityKey,
    String sessionId,
    String pickle,
    int lastReceived,
  );

  Future setLastActiveUserDeviceKey(
    int lastActive,
    String userId,
    String deviceId,
  );

  Future setLastSentMessageUserDeviceKey(
    String lastSentMessage,
    String userId,
    String deviceId,
  );

  Future clearSSSSCache();

  Future storeSSSSCache(
    String type,
    String keyId,
    String ciphertext,
    String content,
  );

  Future markInboundGroupSessionsAsNeedingUpload();

  Future storePrevBatch(
    String prevBatch,
  );

  Future deleteOldFiles(int savedAt);

  Future storeUserDeviceKeysInfo(
    String userId,
    bool outdated,
  );

  Future storeUserDeviceKey(
    String userId,
    String deviceId,
    String content,
    bool verified,
    bool blocked,
    int lastActive,
  );

  Future removeUserDeviceKey(
    String userId,
    String deviceId,
  );

  Future removeUserCrossSigningKey(
    String userId,
    String publicKey,
  );

  Future storeUserCrossSigningKey(
    String userId,
    String publicKey,
    String content,
    bool verified,
    bool blocked,
  );

  Future deleteFromToDeviceQueue(int id);

  Future removeEvent(String eventId, String roomId);

  Future setRoomPrevBatch(
    String? prevBatch,
    String roomId,
    Client client,
  );

  Future setVerifiedUserCrossSigningKey(
    bool verified,
    String userId,
    String publicKey,
  );

  Future setBlockedUserCrossSigningKey(
    bool blocked,
    String userId,
    String publicKey,
  );

  Future setVerifiedUserDeviceKey(
    bool verified,
    String userId,
    String deviceId,
  );

  Future setBlockedUserDeviceKey(
    bool blocked,
    String userId,
    String deviceId,
  );

  Future<List<Event>> getUnimportantRoomEventStatesForRoom(
    List<String> events,
    Room room,
  );

  Future<List<OlmSession>> getOlmSessions(
    String identityKey,
    String userId,
  );

  Future<Map<String, Map>> getAllOlmSessions();

  Future<List<OlmSession>> getOlmSessionsForDevices(
    List<String> identityKeys,
    String userId,
  );

  Future<List<QueuedToDeviceEvent>> getToDeviceEventQueue();

  /// Please do `jsonEncode(content)` in your code to stay compatible with
  /// auto generated methods here.
  Future insertIntoToDeviceQueue(
    String type,
    String txnId,
    String content,
  );

  Future<List<String>> getLastSentMessageUserDeviceKey(
    String userId,
    String deviceId,
  );

  Future<List<StoredInboundGroupSession>> getInboundGroupSessionsToUpload();

  Future<void> addSeenDeviceId(
      String userId, String deviceId, String publicKeys);

  Future<void> addSeenPublicKey(String publicKey, String deviceId);

  Future<String?> deviceIdSeen(userId, deviceId);

  Future<String?> publicKeySeen(String publicKey);

  Future<dynamic> close();

  Future<void> transaction(Future<void> Function() action);

  Future<String> exportDump();

  Future<bool> importDump(String export);

  Future<void> storePresence(String userId, CachedPresence presence);

  Future<CachedPresence?> getPresence(String userId);

  Future<void> storeWellKnown(DiscoveryInformation? discoveryInformation);

  Future<DiscoveryInformation?> getWellKnown();

  /// Deletes the whole database. The database needs to be created again after
  /// this.
  Future<void> delete();
}

/// Streaming JSON string-array decoder; retains one encoded ID and <=256 IDs.
/// UTF-8 is decoded per JSON string so arbitrary byte chunk boundaries are safe.
class TimelineStringArrayParser {
  final _token = <int>[];
  final _page = <String>[];
  bool _started = false,
      _ended = false,
      _inString = false,
      _escaped = false,
      _expectValue = true;
  bool _hasValue = false;
  Iterable<List<String>> add(List<int> bytes) sync* {
    for (final b in bytes) {
      if (_inString) {
        _token.add(b);
        if (_escaped) {
          _escaped = false;
          continue;
        }
        if (b == 92) {
          _escaped = true;
          continue;
        }
        if (b != 34) continue;
        _inString = false;
        _page.add(jsonDecode(utf8.decode(_token)) as String);
        _token.clear();
        _expectValue = false;
        _hasValue = true;
        if (_page.length == 256) {
          yield List.of(_page);
          _page.clear();
        }
      } else {
        if (b == 32 || b == 9 || b == 10 || b == 13) continue;
        if (!_started && b == 91) {
          _started = true;
          continue;
        }
        if (!_started || _ended) {
          throw const FormatException('Invalid timeline source');
        }
        if (b == 93 && (!_expectValue || !_hasValue)) {
          _ended = true;
          continue;
        }
        if (b == 44 && !_expectValue) {
          _expectValue = true;
          continue;
        }
        if (b == 34 && _expectValue) {
          _inString = true;
          _token.add(b);
          continue;
        }
        throw const FormatException('Invalid timeline source');
      }
    }
  }

  Iterable<List<String>> finish() sync* {
    if (!_ended || _inString) {
      throw const FormatException('Incomplete timeline source');
    }
    if (_page.isNotEmpty) {
      yield List.of(_page);
      _page.clear();
    }
  }
}
