import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../network_state_manager.dart';
import 'media_outbox_store.dart';
import 'server_retry_policy.dart';

typedef MediaOutboxSender = Future<String> Function(
    MediaOutboxTask task, File source);

/// Account-owned recovery. SDK upload/event/ACK is one real transport Future;
/// a display timeout never relinquishes this transaction's transport ownership.
final class MediaOutboxRecoveryService extends ChangeNotifier {
  MediaOutboxRecoveryService(
      {required this.store,
      required this.isCurrentOwner,
      required this.authorize,
      required this.send,
      DateTime Function()? now,
      this.failureReason,
      this.checkpoint})
      : _now = now ?? DateTime.now;
  final SqliteMediaOutboxStore store;
  final bool Function() isCurrentOwner;
  final Future<bool> Function(MediaOutboxTask task) authorize;
  final MediaOutboxSender send;
  final DateTime Function() _now;
  final Future<void> Function(String boundary)? checkpoint;
  final String? Function(Object error)? failureReason;
  static final current = ValueNotifier<MediaOutboxRecoveryService?>(null);
  static MediaOutboxRecoveryService? get shared => current.value;
  static set shared(MediaOutboxRecoveryService? value) => current.value = value;
  static final _flights = <(String, String), Future<String>>{};
  static final _roomSlots = <String, _MediaRoomSlots>{};
  static final _foreground = <(String, String), Set<Object>>{};
  final _ownedHolds = <(String, String), Set<Object>>{};
  bool _active = true;
  bool _disposed = false;
  Future<void>? _recovery;
  bool _reconciled = false;
  Timer? _retry;
  bool get active => _active && isCurrentOwner();

  void _ensureActive() {
    if (!active) throw const MediaOutboxException('owner-unavailable');
  }

  /// Persists before admission into either this recovery sender or a foreground
  /// queue. The selected file remains owned by the caller.
  Future<MediaOutboxTask> persistFile(
      {required String txid,
      required String roomId,
      required File source,
      required String mimeType,
      required String filename,
      int? durationMs,
      bool prepared = false,
      bool asFile = false,
      int? width,
      int? height}) async {
    _ensureActive();
    final task = await _observePersistence(
        txid,
        store.persistFile(
            txid: txid,
            roomId: roomId,
            source: source,
            mimeType: mimeType,
            filename: filename,
            durationMs: durationMs,
            prepared: prepared,
            asFile: asFile,
            width: width,
            height: height,
            isCurrentOwner: () => active));
    _ensureActive();
    _changed();
    return task;
  }

  Future<MediaOutboxTask> persistBytes(
      {required String txid,
      required String roomId,
      required Uint8List bytes,
      required String mimeType,
      required String filename,
      int? durationMs,
      bool prepared = false,
      bool asFile = false,
      int? width,
      int? height}) async {
    _ensureActive();
    final task = await _observePersistence(
        txid,
        store.persistBytes(
            txid: txid,
            roomId: roomId,
            bytes: bytes,
            mimeType: mimeType,
            filename: filename,
            durationMs: durationMs,
            prepared: prepared,
            asFile: asFile,
            width: width,
            height: height,
            isCurrentOwner: () => active));
    _ensureActive();
    _changed();
    return task;
  }

  Future<MediaOutboxTask> persistPreparedBytes(
      {required String txid,
      required String roomId,
      required Future<Uint8List> Function() load,
      required String mimeType,
      required String filename,
      int? durationMs,
      bool prepared = false,
      bool asFile = false,
      int? width,
      int? height}) async {
    _ensureActive();
    final task = await _observePersistence(
        txid,
        store.persistPreparedBytes(
            txid: txid,
            roomId: roomId,
            load: load,
            mimeType: mimeType,
            filename: filename,
            durationMs: durationMs,
            prepared: prepared,
            asFile: asFile,
            width: width,
            height: height,
            isCurrentOwner: () => active));
    _ensureActive();
    _changed();
    return task;
  }

  /// Reserve a persisted intent while its existing coordinator prepares it.
  /// The returned release must run after real preparation/transport settlement.
  VoidCallback holdForeground(String txid) {
    _ensureActive();
    final key = (store.owner.scope, txid);
    final token = Object();
    _foreground.putIfAbsent(key, () => {}).add(token);
    _ownedHolds.putIfAbsent(key, () => {}).add(token);
    return () {
      _foreground[key]?.remove(token);
      _ownedHolds[key]?.remove(token);
      if (_foreground[key]?.isEmpty == true) _foreground.remove(key);
      if (_ownedHolds[key]?.isEmpty == true) _ownedHolds.remove(key);
    };
  }

  Future<MediaOutboxTask> _observePersistence(
      String txid, Future<MediaOutboxTask> operation) async {
    try {
      return await operation;
    } catch (error) {
      final reason = failureReason?.call(error);
      if (active && reason != null) {
        await store.setStage(txid, MediaOutboxStage.failed,
            from: {MediaOutboxStage.preparing, MediaOutboxStage.failed},
            failure: reason);
      }
      rethrow;
    } finally {
      _changed();
    }
  }

  Future<MediaOutboxTask> persistResolvedFile({
    required String txid,
    required String roomId,
    required Future<File> Function() resolve,
    required String mimeType,
    required String filename,
  }) async {
    _ensureActive();
    try {
      final task = await store.persistResolvedFile(
          txid: txid,
          roomId: roomId,
          resolve: resolve,
          mimeType: mimeType,
          filename: filename,
          isCurrentOwner: () => active);
      _ensureActive();
      return task;
    } finally {
      _changed();
    }
  }

  Future<String> dispatch(MediaOutboxTask task,
      {bool userRetry = false, MediaOutboxSender? senderOverride}) {
    final key = (store.owner.scope, task.txid);
    if (task.ownerScope != key.$1 || !active) {
      return Future.error(const MediaOutboxException('owner-unavailable'));
    }
    final pending = _flights[key];
    if (pending != null) return pending;
    late final Future<String> flight;
    flight = _roomSlots
        .putIfAbsent(key.$1, _MediaRoomSlots.new)
        .run(
            task.roomId,
            () => _dispatch(task.txid,
                userRetry: userRetry, sender: senderOverride ?? send))
        .whenComplete(() {
      if (identical(_flights[key], flight)) _flights.remove(key);
    });
    _flights[key] = flight;
    return flight;
  }

  Future<String> _dispatch(String txid,
      {required bool userRetry, required MediaOutboxSender sender}) async {
    var task = await store.byTxid(txid);
    _ensureActive();
    if (task == null) throw const MediaOutboxException('task-missing');
    if (task.stage == MediaOutboxStage.sent && task.eventId != null) {
      return task.eventId!;
    }
    if (task.stage == MediaOutboxStage.canceled) {
      throw const MediaOutboxException('canceled');
    }
    // A manual retry does not shorten an explicit server deadline.
    if (task.nextRetryAt?.isAfter(_now()) == true ||
        (task.stage == MediaOutboxStage.failed && !userRetry)) {
      throw const MediaOutboxException('retry-not-due');
    }
    if (userRetry && task.stage == MediaOutboxStage.sending) {
      // dispatch's shared flight map already joined any real live attempt.
      // Thus this is an orphaned interruption, retried with its original txid.
      await store.setStage(txid, MediaOutboxStage.ackUnknown,
          from: {MediaOutboxStage.sending}, failure: 'ack-unknown');
      _ensureActive();
    }
    try {
      if (!await authorize(task)) {
        throw const MediaOutboxException('permission-denied');
      }
      _ensureActive();
      final source = await store.verifiedSource(task);
      _ensureActive();
      final claimed = await store.setStage(txid, MediaOutboxStage.sending,
          from: {
            MediaOutboxStage.queued,
            MediaOutboxStage.ackUnknown,
            if (userRetry) MediaOutboxStage.failed
          },
          incrementAttempt: true);
      _ensureActive();
      if (!claimed) throw const MediaOutboxException('not-admitted');
      task = (await store.byTxid(txid))!;
      _ensureActive();
      if (task.stage != MediaOutboxStage.sending) {
        throw const MediaOutboxException('canceled');
      }
      await checkpoint?.call('sending');
      _ensureActive();
      final eventId = await sender(task, source);
      await checkpoint?.call('ack');
      _ensureActive();
      if (eventId.isEmpty) {
        throw const MessageSendNetworkException('ACK unknown');
      }
      final accepted = await store.setStage(txid, MediaOutboxStage.sent,
          from: {MediaOutboxStage.sending}, eventId: eventId);
      if (!accepted) throw const MediaOutboxException('canceled');
      return eventId;
    } catch (error) {
      // StateError/ArgumentError are used by the existing SDK permission and
      // media validators. They are permanent outcomes, not stuck `sending`.
      if (error is Error && error is! StateError && error is! ArgumentError) {
        rethrow;
      }
      if (active) {
        if (defaultNetworkFailureClassifier(error)) {
          final delay = ServerRetryPolicy.delay(
              ((task?.attempts ?? 1) - 1).clamp(0, 1000), error);
          await store.setStage(
              txid,
              delay == null
                  ? MediaOutboxStage.failed
                  : MediaOutboxStage.ackUnknown,
              from: {
                MediaOutboxStage.queued,
                MediaOutboxStage.sending,
                MediaOutboxStage.ackUnknown
              },
              failure: 'ack-unknown',
              incrementAttempt: task?.stage != MediaOutboxStage.sending,
              nextRetryAt: _retryDeadline(error, delay));
          if (delay != null) _schedule(delay);
        } else {
          await store.setStage(txid, MediaOutboxStage.failed,
              from: {
                MediaOutboxStage.preparing,
                MediaOutboxStage.queued,
                MediaOutboxStage.sending,
                MediaOutboxStage.ackUnknown,
                MediaOutboxStage.failed
              },
              failure: error is MediaOutboxException
                  ? error.reason
                  : failureReason?.call(error) ?? 'send-rejected');
        }
      }
      rethrow;
    } finally {
      // Includes a canceled request that finally settled. A suspended account
      // leaves its nonterminal original intact for its own later generation.
      await store.releaseTerminalSource(txid);
      _changed();
    }
  }

  /// This lock covers only discovery/admission. A real hanging transport is
  /// still held by _flights/_roomSlots but never suppresses later scans.
  Future<void> recover({bool waitForSettlement = false}) async {
    await (_recovery ??= _recover().whenComplete(() => _recovery = null));
    if (waitForSettlement) {
      // Explicit diagnostic/test wait; production resume/timers use the default.
      final attempts = [
        for (final entry in _flights.entries)
          if (entry.key.$1 == store.owner.scope) entry.value
      ];
      await Future.wait([
        for (final attempt in attempts)
          attempt.then<void>((_) {}, onError: (Object _, StackTrace __) {})
      ]);
    }
  }

  DateTime? _retryDeadline(Object error, Duration? automaticDelay) {
    var milliseconds = automaticDelay?.inMilliseconds ?? 0;
    try {
      final dynamic failure = error;
      final Object? value = failure.retryAfterMs;
      if (value is int && value > milliseconds) milliseconds = value;
    } catch (_) {}
    try {
      final dynamic failure = error;
      final Object? value = failure.retryAfterSeconds;
      if (value is int && value > 0 && value * 1000 > milliseconds) {
        milliseconds = value * 1000;
      }
    } catch (_) {}
    if (milliseconds <= 0) return null;
    // Preserve even deadlines beyond the bounded automatic retry policy.
    return DateTime.fromMillisecondsSinceEpoch(
        (_now().millisecondsSinceEpoch + milliseconds)
            .clamp(0, 8640000000000000));
  }

  Future<void> _recover() async {
    _ensureActive();
    await store.cleanupTerminalSources(
        canRelease: (txid) =>
            active && !_flights.containsKey((store.owner.scope, txid)));
    _ensureActive();
    final tasks = await store.pending();
    _ensureActive();
    if (!_reconciled) {
      for (final task in tasks) {
        if (_flights.containsKey((task.ownerScope, task.txid)) ||
            _foreground.containsKey((task.ownerScope, task.txid))) {
          continue;
        }
        _ensureActive();
        if (task.stage == MediaOutboxStage.sending) {
          await store.setStage(task.txid, MediaOutboxStage.ackUnknown,
              from: {MediaOutboxStage.sending}, failure: 'ack-unknown');
        } else if (task.stage == MediaOutboxStage.preparing) {
          await store.setStage(task.txid, MediaOutboxStage.failed,
              from: {MediaOutboxStage.preparing}, failure: 'source-incomplete');
        }
      }
      _reconciled = true;
    }
    for (final task in await store.pending()) {
      _ensureActive();
      if (_foreground.containsKey((task.ownerScope, task.txid))) continue;
      if (task.stage == MediaOutboxStage.failed ||
          task.stage == MediaOutboxStage.preparing) {
        continue;
      }
      if (task.nextRetryAt?.isAfter(_now()) == true) {
        _schedule(task.nextRetryAt!.difference(_now()));
        continue;
      }
      unawaited(_observeRecoveryAttempt(task.txid, dispatch(task)));
    }
    _changed();
  }

  Future<void> _observeRecoveryAttempt(
      String txid, Future<String> attempt) async {
    try {
      await attempt;
    } catch (_) {
      // _dispatch records expected failures. An unexpected local interruption
      // leaves the original/intention intact for startup or explicit retry.
      // Observation never writes a later attempt's state or leaks async errors.
    }
  }

  Future<void> cancel(String txid) async {
    _ensureActive();
    await store.setStage(txid, MediaOutboxStage.canceled, from: {
      MediaOutboxStage.preparing,
      MediaOutboxStage.queued,
      MediaOutboxStage.sending,
      MediaOutboxStage.ackUnknown,
      MediaOutboxStage.failed
    });
    if (!_flights.containsKey((store.owner.scope, txid))) {
      await store.releaseTerminalSource(txid);
    }
    _changed();
  }

  void _schedule(Duration delay) {
    if (!active) return;
    // A later task may wake early, but its persisted deadline is checked again.
    _retry ??= Timer(delay, () {
      _retry = null;
      if (active) unawaited(recover().catchError((Object _) {}));
    });
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void suspend() {
    _active = false;
    _retry?.cancel();
    _retry = null;
  }

  Future<void> close() async {
    suspend();
    final pending = [
      for (final entry in _flights.entries)
        if (entry.key.$1 == store.owner.scope) entry.value
    ];
    await Future.wait([
      for (final flight in pending)
        flight.then<void>((_) {}, onError: (Object _, StackTrace __) {})
    ]);
    await store.close();
  }

  @override
  void dispose() {
    suspend();
    _disposed = true;
    super.dispose();
  }
}

/// Shared by foreground/recovery and replacement instances of one owner.
/// A queued request retains only metadata. At most two distinct rooms run;
/// the next eligible room skips an occupied room without overtaking within it.
final class _MediaRoomSlots {
  final _pending = <_MediaRoomRequest>[];
  final _activeRooms = <String>{};
  Future<String> run(String roomId, Future<String> Function() action) {
    final request = _MediaRoomRequest(roomId, action);
    _pending.add(request);
    _pump();
    return request.result.future;
  }

  void _pump() {
    while (_activeRooms.length < 2) {
      final index =
          _pending.indexWhere((r) => !_activeRooms.contains(r.roomId));
      if (index < 0) return;
      final request = _pending.removeAt(index);
      _activeRooms.add(request.roomId);
      unawaited(_run(request));
    }
  }

  Future<void> _run(_MediaRoomRequest request) async {
    try {
      request.result.complete(await request.action());
    } catch (error, stack) {
      request.result.completeError(error, stack);
    } finally {
      _activeRooms.remove(request.roomId);
      _pump();
    }
  }
}

final class _MediaRoomRequest {
  _MediaRoomRequest(this.roomId, this.action);
  final String roomId;
  final Future<String> Function() action;
  final result = Completer<String>();
}
