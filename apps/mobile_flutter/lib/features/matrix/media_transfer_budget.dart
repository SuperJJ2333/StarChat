import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'media_consumer_scope.dart';
import 'media_load_scheduler.dart';

const defaultMediaTransferBytes = 192 * 1024 * 1024;
const defaultMediaDownloadBytes = defaultMediaTransferBytes ~/ 4;
const mediaDecodeWorkingBytes = 64 * 1024 * 1024;
const mediaThumbnailReserveBytes = 512 * 1024;

/// Header detection only chooses a conservative work estimate, never content
/// authority. The media parser and SDK still validate the actual bytes.
bool mediaNeedsDecode(String mimeType, List<int> header) =>
    mimeType.startsWith('image/') ||
    mimeType.startsWith('video/') ||
    (header.length >= 3 &&
        ((header[0] == 71 && header[1] == 73 && header[2] == 70) ||
            (header[0] == 255 && header[1] == 216 && header[2] == 255))) ||
    (header.length >= 8 &&
        header[0] == 137 &&
        header[1] == 80 &&
        header[2] == 78 &&
        header[3] == 71) ||
    (header.length >= 12 &&
        header[0] == 82 &&
        header[1] == 73 &&
        header[2] == 70 &&
        header[3] == 70 &&
        header[8] == 87 &&
        header[9] == 69 &&
        header[10] == 66 &&
        header[11] == 80);

MediaTransferPlan mediaUploadPlan(int bytes,
    {required String mimeType,
    List<int> header = const [],
    int thumbnailBytes = 0,
    bool copySource = false}) {
  final visual = mediaNeedsDecode(mimeType, header);
  final thumbnail = visual && thumbnailBytes < mediaThumbnailReserveBytes
      ? mediaThumbnailReserveBytes
      : thumbnailBytes;
  // Resizing a very compact PNG can produce a larger (but <=500KiB) JPEG.
  // Reserve that final encoding before decoding, not only the input length.
  final encoded = visual && bytes < mediaThumbnailReserveBytes
      ? mediaThumbnailReserveBytes
      : bytes;
  return MediaTransferPlan.upload(encoded,
      thumbnailBytes: thumbnail,
      extraSourceCopies: copySource ? 1 : 0,
      decodedBytes: visual ? mediaDecodeWorkingBytes : 0);
}

/// Conservative logical live-array work, not process RSS or native/GPU memory.
/// Reserve the complete peak before starting; stage-by-stage acquisition can
/// deadlock when every task holds its source while waiting for ciphertext.
final class MediaTransferPlan {
  const MediaTransferPlan(
      {this.sourceBytes = 0,
      this.ciphertextBytes = 0,
      this.downloadBytes = 0,
      this.decodedBytes = 0,
      this.encodedCopies = 4,
      required this.payloadBytes});
  factory MediaTransferPlan.upload(int bytes,
          {int thumbnailBytes = 0,
          int decodedBytes = 0,
          int extraSourceCopies = 0}) =>
      MediaTransferPlan(
          // Caller source, verified immutable snapshot and encryption worker input.
          sourceBytes: (3 + extraSourceCopies) * (bytes + thumbnailBytes),
          ciphertextBytes: bytes + thumbnailBytes,
          decodedBytes: decodedBytes,
          encodedCopies: 4 + extraSourceCopies,
          payloadBytes: bytes);
  factory MediaTransferPlan.download(int bytes) => MediaTransferPlan(
      // HTTP chunks/coalescing, ciphertext + native decrypt/verification copies.
      sourceBytes: 2 * bytes,
      ciphertextBytes: bytes,
      downloadBytes: bytes,
      payloadBytes: bytes);
  final int sourceBytes,
      ciphertextBytes,
      downloadBytes,
      decodedBytes,
      encodedCopies,
      payloadBytes;
  int get totalBytes =>
      sourceBytes + ciphertextBytes + downloadBytes + decodedBytes;
  int get maximumPayloadBytes =>
      decodedBytes > 0 && payloadBytes < mediaThumbnailReserveBytes
          ? mediaThumbnailReserveBytes
          : payloadBytes;
}

final class MediaTransferLimitException implements Exception {
  const MediaTransferLimitException(this.maximumPayloadBytes);
  final int maximumPayloadBytes;
  @override
  String toString() => '附件超过当前内存预算（此操作最多 $maximumPayloadBytes 字节），请缩小或压缩后重试';
}

final class _Reservation {
  _Reservation(this.budget, this.plan);
  final MediaTransferBudget budget;
  final MediaTransferPlan plan;
  int users = 1;
  void retain() => users++;
  void release() {
    if (--users == 0) budget._release(plan.totalBytes);
  }
}

final class _Context {
  _Context(this.reservation);
  final _Reservation reservation;
  bool childRunning = false;
  bool active = true;
}

final class _Waiter {
  _Waiter(this.plan, this.scope);
  final MediaTransferPlan plan;
  final MediaConsumerScope? scope;
  final ready = Completer<_Reservation>();
  void Function()? cancel;
}

final class MediaTransferBudget {
  MediaTransferBudget(
      {this.maxBytes = defaultMediaTransferBytes, this.maxQueued = 64}) {
    if (maxBytes <= 0 || maxQueued < 0) {
      throw ArgumentError('Invalid media transfer budget');
    }
  }
  final int maxBytes, maxQueued;
  static const _zoneKey = #chatflowMediaTransferReservation;
  final _waiters = Queue<_Waiter>();
  int _active = 0, _peak = 0;
  int get activeBytes => _active;
  int get peakBytes => _peak;
  int get queuedCount => _waiters.length;
  static MediaTransferPlan? get currentPlan =>
      (Zone.current[_zoneKey] as _Context?)?.reservation.plan;
  int maximumUploadBytes({int decodedBytes = 0, int thumbnailBytes = 0}) =>
      ((maxBytes - decodedBytes) ~/ 4 - thumbnailBytes).clamp(0, maxBytes);
  void check(MediaTransferPlan plan) {
    if (plan.totalBytes > maxBytes) {
      final auxiliary =
          plan.totalBytes - plan.encodedCopies * plan.payloadBytes;
      throw MediaTransferLimitException(
          ((maxBytes - auxiliary) ~/ plan.encodedCopies).clamp(0, maxBytes));
    }
  }

  Future<T> run<T>(MediaTransferPlan plan, Future<T> Function() action) async {
    if ([
          plan.sourceBytes,
          plan.ciphertextBytes,
          plan.downloadBytes,
          plan.decodedBytes,
          plan.payloadBytes
        ].any((n) => n < 0) ||
        plan.encodedCopies < 4 ||
        plan.sourceBytes + plan.ciphertextBytes + plan.downloadBytes <
            plan.encodedCopies * plan.payloadBytes) {
      throw ArgumentError('Invalid media transfer work');
    }
    final scope = MediaConsumerScope.current;
    if (scope != null && !scope.isActive) throw MediaLoadCanceled();
    final parent = Zone.current[_zoneKey] as _Context?;
    final inherited = parent?.reservation;
    late final _Reservation reservation;
    if (inherited != null) {
      if (!parent!.active || inherited.users <= 0) {
        throw StateError('Media transfer owner already settled');
      }
      final available = inherited.plan;
      if (plan.totalBytes > available.totalBytes ||
          plan.payloadBytes > available.maximumPayloadBytes ||
          plan.decodedBytes > available.decodedBytes) {
        throw MediaTransferLimitException(available.payloadBytes);
      }
      // Independent siblings need independent peaks. Never silently reuse one
      // reservation for concurrent children or queue behind our own bytes.
      if (parent.childRunning) {
        throw StateError('Concurrent nested media work');
      }
      parent.childRunning = true;
      inherited.retain();
      reservation = inherited;
    } else {
      check(plan);
      reservation = await _acquire(plan, scope);
    }
    final context = _Context(reservation);
    try {
      if (scope != null && !scope.isActive) throw MediaLoadCanceled();
      final result = await runZoned(() => Future<T>.sync(action),
          zoneValues: {_zoneKey: context});
      if (scope != null && !scope.isActive) throw MediaLoadCanceled();
      return result;
    } finally {
      context.active = false;
      if (inherited != null) parent!.childRunning = false;
      // Cancellation is not completion. Children which outlive an early
      // scheduler/caller cancellation keep this reference until real settle.
      reservation.release();
    }
  }

  Future<_Reservation> _acquire(
      MediaTransferPlan plan, MediaConsumerScope? scope) {
    if (_waiters.isEmpty && _active + plan.totalBytes <= maxBytes) {
      return Future.value(_grant(plan));
    }
    if (_waiters.length >= maxQueued) {
      return Future.error(StateError('媒体任务过多，请稍后重试'));
    }
    final waiter = _Waiter(plan, scope);
    waiter.cancel = () {
      if (!_waiters.remove(waiter)) return;
      scope?.removeCancelListener(waiter.cancel!);
      waiter.ready.completeError(MediaLoadCanceled());
      _drain();
    };
    _waiters.add(waiter);
    scope?.addCancelListener(waiter.cancel!);
    return waiter.ready.future;
  }

  _Reservation _grant(MediaTransferPlan plan) {
    _active += plan.totalBytes;
    if (_active > _peak) _peak = _active;
    return _Reservation(this, plan);
  }

  void _release(int bytes) {
    _active -= bytes;
    _drain();
  }

  void _drain() {
    while (_waiters.isNotEmpty &&
        _active + _waiters.first.plan.totalBytes <= maxBytes) {
      final next = _waiters.removeFirst();
      next.scope?.removeCancelListener(next.cancel!);
      next.ready.complete(_grant(next.plan));
    }
  }
}

/// One process-wide instance across room services, downloads and worker work.
final sharedMediaTransferBudget = MediaTransferBudget();

/// Bound the actual read as well as the earlier stat: a source can grow while
/// waiting. openRead's end caps IO; the extra byte detects growth without a
/// whole-file allocation. The caller must already own a peak reservation.
Future<Uint8List> readMediaFileBounded(File file, int maximumBytes) async {
  final plan = MediaTransferBudget.currentPlan;
  if (plan == null ||
      maximumBytes < 0 ||
      maximumBytes > plan.maximumPayloadBytes) {
    throw StateError('Media file read requires prior byte admission');
  }
  final result = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in file.openRead(0, maximumBytes + 1)) {
    if (MediaConsumerScope.current?.isActive == false) {
      throw MediaLoadCanceled();
    }
    length += chunk.length;
    if (length > maximumBytes) throw MediaTransferLimitException(maximumBytes);
    result.add(chunk);
  }
  return result.takeBytes();
}
