import 'dart:async';
import 'dart:math';

import 'package:matrix/src/voip/utils/voip_constants.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

/// Coalesces gathered local ICE candidates into bounded `m.call.candidates`
/// batches for a single call session.
///
/// MSC2746 does not support trickle ICE, so candidates may not be published one
/// event per candidate: that would multiply the number of requests and would
/// still leave the peer without connectivity until a batch arrives. This queue
/// therefore keeps the batching, but it removes the delay that used to sit on
/// the `answerSent -> iceConnected` critical path:
///
/// * once `m.call.invite` / `m.call.answer` has been published the first batch is
///   only held back for [CallTimeouts.firstCandidateFlush] instead of the old
///   unconditional 500 ms (incoming) / 2000 ms (outgoing) wait;
/// * later batches are coalesced inside [CallTimeouts.candidateBatchWindow];
/// * `iceGatheringState == complete` flushes immediately;
/// * a failed batch is retried with the historical exponential backoff
///   (`retryBase * 2^attempt`) and is never lost, so a transient send failure
///   cannot silently drop the candidates the peer needs;
/// * after [CallTimeouts.candidateSendMaxTries] failed retries the owner is told
///   to abandon the call ([onSendAbandoned]); the bound is deliberately not
///   raised to hide failures.
///
/// One instance belongs to exactly one call session. [cancelAndDispose] bumps an
/// internal generation, so a timer - or a send that is still in flight - created
/// for a previous call can never emit candidates for its replacement.
class CandidateSendQueue {
  CandidateSendQueue({
    required Future<void> Function(List<RTCIceCandidate> candidates) send,
    void Function(int tries)? onSendAbandoned,
    this.firstFlushDelay = CallTimeouts.firstCandidateFlush,
    this.batchWindow = CallTimeouts.candidateBatchWindow,
    this.gatheringFallbackDelay = CallTimeouts.iceGatheringFallback,
    this.retryBase = CallTimeouts.candidateSendRetryBase,
    this.maxTries = CallTimeouts.candidateSendMaxTries,
  })  : _send = send,
        _onSendAbandoned = onSendAbandoned;

  final Future<void> Function(List<RTCIceCandidate> candidates) _send;
  final void Function(int tries)? _onSendAbandoned;

  /// Settle window for the first batch after the invite/answer was sent.
  final Duration firstFlushDelay;

  /// Coalescing window for every batch after the first one.
  final Duration batchWindow;

  /// Fallback flush while ice gathering is still in progress.
  final Duration gatheringFallbackDelay;

  /// Base of the exponential backoff applied to a failed batch.
  final Duration retryBase;

  /// Failed retries tolerated before the call is abandoned.
  final int maxTries;

  final List<RTCIceCandidate> _pending = [];
  Timer? _flushTimer;
  Timer? _gatheringFallbackTimer;
  bool _disposed = false;
  bool _abandoned = false;
  bool _maySend = false;
  bool _sentBatch = false;
  bool _sending = false;
  int _tries = 0;
  int _generation = 0;

  /// Number of candidates waiting for their batch to be flushed.
  int get pendingCandidates => _pending.length;

  /// Failed send attempts of the batch currently being retried.
  int get failedTries => _tries;

  /// Whether this queue has been permanently closed by [cancelAndDispose] or by
  /// exhausting [maxTries].
  bool get isClosed => _disposed || _abandoned;

  /// Queues a freshly gathered candidate. Wired to `pc.onIceCandidate`.
  ///
  /// Candidates are collected even while the invite/answer has not been sent
  /// yet, but they are only *sent* after [onInviteOrAnswerSent], because the
  /// remote peer cannot use them before it holds our SDP.
  void add(RTCIceCandidate candidate) {
    if (isClosed) return;
    _pending.add(candidate);
    if (!_maySend) return;
    _scheduleFlush(_sentBatch ? batchWindow : firstFlushDelay);
  }

  /// The invite or the answer has been published: gathered candidates may be
  /// sent from now on. Flushes whatever was collected meanwhile.
  void onInviteOrAnswerSent() {
    if (isClosed) return;
    _maySend = true;
    if (_pending.isEmpty) return;
    _scheduleFlush(_sentBatch ? batchWindow : firstFlushDelay);
  }

  /// Gathering started. Arms the cancellable fallback flush that makes sure
  /// gathered candidates are not held hostage by a gathering state that never
  /// reaches `complete`.
  void onGatheringStarted() {
    if (isClosed) return;
    _gatheringFallbackTimer?.cancel();
    _gatheringFallbackTimer = Timer(gatheringFallbackDelay, () {
      _gatheringFallbackTimer = null;
      unawaited(_flush());
    });
  }

  /// Gathering completed: cancel the pending timers and send the rest now.
  Future<void> onGatheringComplete() async {
    if (isClosed) return;
    _cancelGatheringFallback();
    _cancelFlushTimer();
    await _flush();
  }

  /// Drops candidates that became useless (peer connection connected, ICE
  /// restart). Does not close the queue.
  void clear() {
    _pending.clear();
    _cancelFlushTimer();
  }

  /// The call is over. After this no timer, retry or in-flight send of this
  /// queue may ever produce another `m.call.candidates` event.
  void cancelAndDispose() {
    _disposed = true;
    _generation++;
    _cancelGatheringFallback();
    _cancelFlushTimer();
    _pending.clear();
  }

  void _cancelFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _cancelGatheringFallback() {
    _gatheringFallbackTimer?.cancel();
    _gatheringFallbackTimer = null;
  }

  /// Schedules the batch flush.
  ///
  /// The window is anchored on the first candidate of the batch and is not
  /// extended by later candidates: a continuous trickle can therefore never
  /// postpone the flush indefinitely, while candidates arriving inside the same
  /// beat are still coalesced into one event.
  void _scheduleFlush(Duration delay) {
    if (isClosed || _flushTimer != null) return;
    final generation = _generation;
    _flushTimer = Timer(delay, () {
      _flushTimer = null;
      if (_disposed || _abandoned || generation != _generation) return;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    if (isClosed || !_maySend || _sending) return;
    if (_pending.isEmpty) return;

    final generation = _generation;
    final batch = List<RTCIceCandidate>.of(_pending);
    _pending.clear();
    _sending = true;
    try {
      await _send(batch);
      if (_disposed || generation != _generation) return;
      _tries = 0;
      _sentBatch = true;
      if (_pending.isNotEmpty) _scheduleFlush(batchWindow);
    } catch (e) {
      if (_disposed || generation != _generation) return;
      _tries++;
      // A failed batch must keep its candidates: without them the peer cannot
      // build a working candidate pair. Newer candidates stay behind them.
      _pending.insertAll(0, batch);
      if (_tries > maxTries) {
        _abandoned = true;
        _cancelFlushTimer();
        _cancelGatheringFallback();
        _pending.clear();
        _onSendAbandoned?.call(_tries);
        return;
      }
      _scheduleFlush(_retryDelay(_tries));
    } finally {
      _sending = false;
    }
  }

  Duration _retryDelay(int tries) =>
      Duration(milliseconds: retryBase.inMilliseconds * pow(2, tries).toInt());
}
