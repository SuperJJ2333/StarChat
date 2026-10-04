import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';
import 'matrix_recovery_vault.dart';

/// Independent history cursor: never calls Room.requestHistory/handleSync.
final class RecentHistoryCoordinator {
  RecentHistoryCoordinator(
      {required this.client,
      required this.owner,
      required this.databaseGeneration,
      required this.status,
      this.vault,
      DateTime? now,
      this.foregroundRoom,
      this.onChanged,
      this.migrateArchives})
      : windowEnd = (now ?? DateTime.now()).millisecondsSinceEpoch,
        head = client.prevBatch;
  final Client client;
  final RecoveryOperationOwner owner;
  final String databaseGeneration;
  final VaultSyncStatus status;
  final MatrixRecoveryVault? vault;
  final int windowEnd;
  String? head;
  final String? Function()? foregroundRoom;
  final void Function()? onChanged;
  final Future<void> Function()? migrateArchives;
  bool _archivesMigrated = false;
  int get windowStart => windowEnd - const Duration(hours: 72).inMilliseconds;
  Future<void>? _running;
  Timer? _retry;
  int _failures = 0;
  bool _revoked = false;
  bool _wakePending = false;
  int retainedEventBodies = 0;
  int maxRetainedEventBodies = 0;
  final Set<String> _replay = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, int> _roomEpochs = {};
  final Map<String, (int, int)> _roomWindows = {};
  Object? _vaultFailure;
  final _counts = <String, ({int downloaded, int decrypted, int missing})>{};

  void start() {
    if (_subscriptions.isEmpty) {
      _subscriptions.add(client.onSync.stream.listen((sync) {
        for (final entry
            in (sync.rooms?.join ?? <String, JoinedRoomUpdate>{}).entries) {
          if (entry.value.timeline?.limited == true) {
            head = sync.nextBatch;
            _roomEpochs[entry.key] = (_roomEpochs[entry.key] ?? 0) + 1;
          }
        }
        wake();
      }));
      _subscriptions.add(client.onEncryptionError.stream.listen((failure) {
        if (owner.active &&
            failure.exception is StateError &&
            (failure.exception as StateError).message ==
                'E2EE_RECOVERY_INDEX_STORAGE_FAILED') {
          status.setPhase(VaultSyncPhase.retrying);
          wake();
        }
      }));
      for (final room in client.rooms) {
        _subscriptions.add(room.onSessionKeyReceived.stream.listen((_) {
          if (owner.active) {
            _replay.add(room.id);
            wake();
          }
        }));
      }
    }
    wake();
  }

  void revoke() {
    _revoked = true;
    _retry?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _replay.clear();
    status.setPhase(VaultSyncPhase.revoked);
  }

  void wake() {
    if (_revoked || !owner.active || _retry != null) return;
    if (_running != null) {
      _wakePending = true;
      return;
    }
    _wakePending = false;
    _running = runOnce().then((_) {
      _failures = 0;
    }, onError: (Object failure, StackTrace _) {
      if (_revoked || !owner.active) return;
      status.setPhase(failure is VaultFailure &&
              {'M_VAULT_UNAVAILABLE', 'M_NOT_FOUND', 'M_UNRECOGNIZED'}
                  .contains(failure.code)
          ? VaultSyncPhase.unavailable
          : VaultSyncPhase.retrying);
      final seconds = [1, 2, 4, 8, 16, 32, 60][_failures.clamp(0, 6)];
      _failures++;
      _retry = Timer(
          Duration(
              milliseconds:
                  (seconds * 1000 * (0.8 + Random().nextDouble() * 0.4))
                      .round()), () {
        _retry = null;
        wake();
      });
    }).whenComplete(() {
      _running = null;
      if (_wakePending && _retry == null && owner.active && !_revoked) wake();
    });
  }

  void retryNow() {
    if (_revoked || !owner.active) return;
    _retry?.cancel();
    _retry = null;
    _failures = 0;
    status.setPhase(VaultSyncPhase.downloading);
    wake();
  }

  /// Also exposed as an awaited deterministic slice for SDK integration tests.
  Future<void> runOnce() async {
    owner.check();
    _vaultFailure = null;
    Future<void> archive() async {
      try {
        await vault?.archiveAvailable();
        if (!_archivesMigrated) {
          await migrateArchives?.call();
          owner.check();
          _archivesMigrated = true;
          if (migrateArchives != null) {
            _replay.addAll(client.rooms.map((r) => r.id));
          }
        }
      } catch (error) {
        owner.check();
        _vaultFailure = error;
      }
    }

    final rooms =
        client.rooms.where((r) => r.membership == Membership.join).toList();
    final foreground = foregroundRoom?.call();
    rooms.sort((a, b) => a.id == foreground
        ? -1
        : b.id == foreground
            ? 1
            : 0);
    Future<void> worker() async {
      while (rooms.isNotEmpty) {
        owner.check();
        final selected =
            rooms.indexWhere((r) => r.id == foregroundRoom?.call());
        final room = rooms.removeAt(selected < 0 ? 0 : selected);
        final complete = await _hydrate(room);
        if (!complete) {
          rooms.add(room);
        } else if (_replay.remove(room.id)) {
          await _replayRoom(room);
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    // History can make durable progress while an older local archive is being
    // protected. Initialization and missing-key queries retain their own lanes.
    await Future.wait([archive(), worker(), worker()]);
    final replay = client.rooms.where((r) => _replay.remove(r.id)).toList();
    var replayNext = 0;
    Future<void> replayWorker() async {
      while (replayNext < replay.length) {
        owner.check();
        await _replayRoom(replay[replayNext++]);
      }
    }

    await Future.wait([replayWorker(), replayWorker()]);
    owner.check();
    if (_vaultFailure != null) throw _vaultFailure!;
    status.setPhase(status.missing > 0 || status.downloaded > status.decrypted
        ? VaultSyncPhase.partial
        : VaultSyncPhase.ready);
  }

  String _checkpointKey(Room room) => sha256
      .convert(utf8.encode(
          '${client.userID}|${client.homeserver}|$databaseGeneration|${room.id}'))
      .toString();

  Future<bool> _hydrate(Room room) async {
    final database = client.database!;
    final key = _checkpointKey(room);
    var checkpoint =
        await owner.read(() => database.getRecoveryCheckpoint(key));
    final epoch = _roomEpochs[room.id] ?? 0;
    // A new login/head must bridge the actual offline gap. Never treat old
    // coverage or a sparse context row as coverage of a new head.
    final sameWindow =
        checkpoint?['head'] == head && checkpoint?['epoch'] == epoch;
    final activeStart =
        sameWindow ? checkpoint!['windowStart'] as int : windowStart;
    final activeEnd = sameWindow ? checkpoint!['windowEnd'] as int : windowEnd;
    _roomWindows[room.id] = (activeStart, activeEnd);
    final walk = sameWindow
        ? (checkpoint!['walk'] ?? head)
        : '$head:${checkpoint?['revision'] ?? 0}';
    final bridge = sameWindow
        ? (checkpoint?['bridge'] as String?)
        : checkpoint?['complete'] == true &&
                (checkpoint?['windowStart'] as int? ?? windowStart + 1) <=
                    windowStart
            ? (checkpoint?['headEvent'] as String?)
            : null;
    String? headEvent =
        sameWindow ? (checkpoint?['headEvent'] as String?) : null;
    if (sameWindow && checkpoint?['complete'] == true) {
      // Coverage and decryption are independent. A committed ciphertext page
      // must retry missing keys even when its history cursor is complete.
      if (_counts[room.id] == null ||
          _counts[room.id]!.missing > 0 ||
          _replay.remove(room.id)) {
        await _replayRoom(room);
      }
      return true;
    }
    var revision = checkpoint?['revision'] as int? ?? 0;
    String? cursor = sameWindow ? (checkpoint?['cursor'] as String?) : head;
    String? anchor = sameWindow ? (checkpoint?['anchor'] as String?) : null;
    if (anchor == null &&
        !(sameWindow && checkpoint?['anchorAttempted'] == true)) {
      try {
        final result = await owner
            .read(() =>
                client.getEventByTimestamp(room.id, activeStart, Direction.b))
            .timeout(const Duration(seconds: 8));
        final event = await owner
            .read(() => client.getOneRoomEvent(room.id, result.eventId))
            .timeout(const Duration(seconds: 8));
        if (event.eventId != result.eventId ||
            (event.toJson()['room_id'] != null &&
                event.toJson()['room_id'] != room.id)) {
          throw const VaultFailure('invalid_history_anchor');
        }
        anchor = result.eventId;
      } on MatrixException catch (error) {
        if (!{'M_UNRECOGNIZED', 'M_NOT_FOUND', 'M_UNSUPPORTED'}
            .contains(error.errcode)) {
          rethrow;
        }
        // Without an order anchor, only real exhaustion proves coverage.
      }
    }
    while (owner.active && !_revoked) {
      final roomEpoch = _roomEpochs[room.id] ?? 0;
      if (roomEpoch != epoch) {
        throw const VaultFailure('history_fragment_changed');
      }
      final page = await owner
          .read(() => client.getRoomEvents(room.id, Direction.b,
              from: cursor, limit: 80))
          .timeout(const Duration(seconds: 8));
      owner.check();
      if ((_roomEpochs[room.id] ?? 0) != epoch) {
        throw const VaultFailure('history_fragment_changed');
      }
      if (page.chunk.length > 80) throw const VaultFailure('oversize_history');
      retainedEventBodies += page.chunk.length;
      if (retainedEventBodies > maxRetainedEventBodies) {
        maxRetainedEventBodies = retainedEventBodies;
      }
      try {
        final complete = page.end == null ||
            page.end == '' ||
            (anchor != null && page.chunk.any((e) => e.eventId == anchor)) ||
            (bridge != null && page.chunk.any((e) => e.eventId == bridge));
        headEvent ??= page.chunk.firstOrNull?.eventId;
        final stalled = !complete &&
            (page.end == cursor ||
                await owner.read(
                    () => database.hasRecoveryCursor('$key:$walk', page.end!)));
        checkpoint = {
          'revision': revision + 1,
          'head': head,
          'windowStart': activeStart,
          'windowEnd': activeEnd,
          'walk': walk,
          'headEvent': headEvent,
          'bridge': bridge,
          'epoch': epoch,
          'cursor': page.end,
          'anchor': anchor,
          'anchorAttempted': true,
          'complete': complete,
          'stalled': stalled
        };
        final committed = await owner.write(() =>
            database.commitRecoveryHistoryPage(room, key, revision,
                page.chunk.map((e) => e.toJson()).toList(), checkpoint!));
        owner.check();
        if (!committed) throw const VaultFailure('checkpoint_conflict');
        revision++;
        await _recoverPage(room, page.chunk.map((e) => e.eventId).toList());
        owner.check();
        onChanged?.call();
        if (complete) return true;
        if (stalled) throw const VaultFailure('history_stalled');
        cursor = page.end;
      } finally {
        retainedEventBodies -= page.chunk.length;
      }
      // Return to the shared two-worker queue after every page. A newly visible
      // room receives the next available slot, without truncating coverage.
      return false;
    }
    owner.check();
    throw const VaultFailure('revoked');
  }

  Future<void> _recoverPage(Room room, List<String> ids) async {
    final database = client.database!;
    final missing = <(String, String), String>{};
    final window = _roomWindows[room.id] ?? (windowStart, windowEnd);
    for (final id in ids) {
      final event = await owner.read(() => database.getEventById(id, room));
      if (event == null ||
          event.type != EventTypes.Encrypted ||
          event.redacted ||
          event.originServerTs.millisecondsSinceEpoch < window.$1 ||
          event.originServerTs.millisecondsSinceEpoch > window.$2) {
        continue;
      }
      final session = event.content['session_id'],
          sender = event.content['sender_key'];
      if (session is! String || sender is! String) continue;
      await owner.read(() async => client.encryption?.keyManager
          .loadInboundGroupSession(room.id, session));
      final decoded = client.encryption?.decryptRoomEventSync(room.id, event);
      if (decoded != null && decoded.type != EventTypes.Encrypted) {
        await client.encryption!.awaitRecoveryIndexPersistence(event.eventId);
        owner.check();
        await owner.write(() => database.storeRecoveryDecryptedEvent(decoded));
        owner.check();
      } else {
        missing[(room.id, session)] = sender;
        if (missing.length == 64) {
          await _restore(room, missing);
          missing.clear();
        }
      }
    }
    if (missing.isNotEmpty) await _restore(room, missing);
    _counts[room.id] =
        await owner.read(() => database.recoveryRoomCounts(room, window.$1));
    owner.check();
    status.downloaded = _counts.values.fold(0, (n, c) => n + c.downloaded);
    status.decrypted = _counts.values.fold(0, (n, c) => n + c.decrypted);
    status.missing = _counts.values.fold(0, (n, c) => n + c.missing);
    status.changed();
  }

  Future<void> _restore(
      Room room, Map<(String, String), String> missing) async {
    var count = 0;
    try {
      count = await vault?.restoreMissing(missing) ?? 0;
    } catch (error) {
      owner.check();
      _vaultFailure = error;
    }
    owner.check();
    try {
      count += await client.encryption?.keyManager
              .restoreNeededNativeBackup(missing, owner) ??
          0;
      owner.check();
      if (count > 0) await vault?.archiveAvailable();
    } on MatrixException catch (error) {
      owner.check();
      if (!{'M_NOT_FOUND', 'M_UNRECOGNIZED'}.contains(error.errcode)) rethrow;
    }
    owner.check();
    if (count > 0) _replay.add(room.id);
  }

  Future<void> _replayRoom(Room room) async {
    // Read from disk in bounded windows; never retain a Timeline or enqueue
    // all ciphertext in the SDK's global pending-decryption collection.
    String? afterEventId;
    final window = _roomWindows[room.id] ?? (windowStart, windowEnd);
    while (owner.active) {
      final page = await owner.read(() => client.database!
          .getRecoveryPendingEventIds(room,
              windowStart: window.$1,
              windowEnd: window.$2,
              afterEventId: afterEventId,
              limit: 80));
      if (page.isEmpty) {
        await _recoverPage(room, const []);
        return;
      }
      await _recoverPage(room, page);
      afterEventId = page.last;
      await Future<void>.delayed(Duration.zero);
    }
  }
}
