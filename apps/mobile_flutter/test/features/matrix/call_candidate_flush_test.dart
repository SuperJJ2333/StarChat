// Regression tests for the ICE candidate flush latency fix (MSC2746 batching).
//
// Two layers are covered:
//
//  * the real `CallSession` production path (`onNegotiationNeeded ->
//    _gotLocalOffer -> sendInviteToCall -> candidate flush`). Only the network
//    edge (`sendCallCandidates`, `sendInviteToCall`) and the WebRTC edge (peer
//    connection, media devices) are faked; the batching/timer logic under test
//    is the shipped one;
//  * the extracted `CandidateSendQueue` unit, for the retry/backoff, give-up
//    bound, dispose and cross-call generation guarantees that cannot be driven
//    through WebRTC without a real peer connection.
//
// All timing is virtual (`fake_async`), so these assertions are about the
// shipped delays and not about machine speed.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:matrix/src/voip/utils/candidate_send_queue.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

/// The historical unconditional first-batch delay that used to sit on the
/// `answerSent -> iceConnected` critical path.
const _historicalFirstBatchDelay = Duration(milliseconds: 2000);

RTCIceCandidate _candidate(String id) => RTCIceCandidate(
      'candidate:$id 1 udp 2122260223 10.0.0.1 5000 typ host',
      'audio',
      0,
    );

class _Stream implements MediaStream {
  @override
  List<MediaStreamTrack> getTracks() => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Media implements MediaDevices {
  @override
  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) async =>
      _Stream();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Only the WebRTC edge: records the callbacks `CallSession` installs so the
/// test can fire ICE events by hand.
class _FakePeer implements RTCPeerConnection {
  @override
  Function(RTCIceCandidate candidate)? onIceCandidate;
  @override
  Function(RTCIceGatheringState state)? onIceGatheringState;
  @override
  Function()? onRenegotiationNeeded;
  @override
  Function(RTCIceConnectionState state)? onIceConnectionState;

  RTCIceGatheringState gatheringState =
      RTCIceGatheringState.RTCIceGatheringStateNew;

  int closeCalls = 0;

  @override
  RTCIceGatheringState? get iceGatheringState => gatheringState;

  @override
  Future<RTCSessionDescription> createOffer(
          [Map<String, dynamic>? constraints]) async =>
      RTCSessionDescription('v=0\r\n', 'offer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<RTCSessionDescription?> getRemoteDescription() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Delegate implements WebRTCDelegate {
  _Delegate(this.peer);

  final _FakePeer peer;

  @override
  MediaDevices get mediaDevices => _Media();

  @override
  Future<RTCPeerConnection> createPeerConnection(
          Map<String, dynamic> configuration,
          [Map<String, dynamic>? constraints]) async =>
      peer;

  @override
  Future<void> stopRingtone() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Real `CallSession`; only the two Matrix event senders are replaced so the
/// emitted batches can be observed without a homeserver.
class _TestCall extends CallSession {
  _TestCall(VoIP voip, Room room, String id)
      : super(CallOptions(
          callId: id,
          type: CallType.kVoice,
          dir: CallDirection.kOutgoing,
          room: room,
          voip: voip,
          localPartyId: 'party-$id',
          iceServers: const [],
        ));

  /// Payload of every `m.call.candidates` event that would have been sent.
  final batches = <List<Map<String, dynamic>>>[];
  final sendAttempts = <int>[];
  final hangupReasons = <CallErrorCode>[];
  int sendFailuresRemaining = 0;

  void failNextSends(int count) => sendFailuresRemaining = count;

  @override
  Future<String?> sendCallCandidates(Room room, String callId, String partyId,
      List<Map<String, dynamic>> candidates,
      {String version = voipProtoVersion, String? txid}) async {
    sendAttempts.add(candidates.length);
    if (sendFailuresRemaining > 0) {
      sendFailuresRemaining--;
      throw StateError('candidate transport down');
    }
    batches.add(candidates);
    return 'ok';
  }

  @override
  Future<String?> sendInviteToCall(
          Room room, String callId, int lifetime, String partyId, String sdp,
          {String type = 'offer',
          String version = voipProtoVersion,
          String? txid,
          CallCapabilities? capabilities,
          SDPStreamMetadata? metadata}) async =>
      'invite-sent';

  @override
  Future<void> addLocalStream(MediaStream stream, String purpose,
      {bool addToPeerConnection = true}) async {}

  @override
  Future<void> hangup(
      {required CallErrorCode reason, bool shouldEmit = true}) async {
    hangupReasons.add(reason);
    setCallState(CallState.kEnded);
  }
}

class _Session {
  _Session(String suffix)
      : client = Client('call-candidate-flush-$suffix'),
        peer = _FakePeer() {
    voip = VoIP(client, _Delegate(peer));
    room = Room(id: '!candidate-flush-$suffix:example.test', client: client);
    call = _TestCall(voip, room, 'call-$suffix');
  }

  final Client client;
  final _FakePeer peer;
  late final VoIP voip;
  late final Room room;
  late final _TestCall call;

  /// Drives the shipped outbound path: prepare peer connection, negotiate,
  /// publish `m.call.invite`, which is the moment `_inviteOrAnswerSent` flips.
  void sendInvite(FakeAsync async) {
    unawaited(call.initOutboundCall(CallType.kVoice));
    async.flushMicrotasks();
    expect(peer.onIceCandidate, isNotNull,
        reason: 'peer connection was prepared');
    peer.onRenegotiationNeeded!();
    async.elapse(CallTimeouts.delayBeforeOffer);
    async.flushMicrotasks();
    expect(call.state, CallState.kInviteSent);
  }

  void gather(String id) => peer.onIceCandidate!(_candidate(id));

  void gatheringComplete() => peer
      .onIceGatheringState!(RTCIceGatheringState.RTCIceGatheringStateComplete);
}

void main() {
  group('CallSession candidate flush (real signalling path)', () {
    test('the first candidate batch is flushed inside the settle window', () {
      fakeAsync((async) {
        final session = _Session('first-flush');
        session.sendInvite(async);

        final gatheredAt = async.elapsed;
        session.gather('first');

        // One beat short of the settle window: still coalescing.
        async.elapse(
            CallTimeouts.firstCandidateFlush - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(session.call.batches, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();

        expect(session.call.batches, hasLength(1));
        expect(session.call.batches.single, hasLength(1));
        expect(session.call.batches.single.single['candidate'],
            contains('candidate:first'));
        expect(session.call.batches.single.single['sdpMid'], 'audio');

        // The defect: the first batch used to wait an unconditional 2000 ms
        // (outgoing) / 500 ms (incoming) even though the peer could already use
        // it. It must now be on the wire far below that, measured from the
        // moment the candidate was gathered.
        final latency = async.elapsed - gatheredAt;
        expect(latency, CallTimeouts.firstCandidateFlush);
        expect(latency, lessThan(_historicalFirstBatchDelay));
        expect(CallTimeouts.firstCandidateFlush,
            lessThan(_historicalFirstBatchDelay));
        expect(CallTimeouts.firstCandidateFlush,
            lessThanOrEqualTo(const Duration(milliseconds: 300)));
      });
    });

    test('candidates gathered in the same beat become one event', () {
      fakeAsync((async) {
        final session = _Session('coalesce');
        session.sendInvite(async);

        session.gather('host');
        async.elapse(const Duration(milliseconds: 10));
        session.gather('srflx');
        async.elapse(const Duration(milliseconds: 10));
        session.gather('relay');

        async.elapse(CallTimeouts.firstCandidateFlush);
        async.flushMicrotasks();

        expect(session.call.batches, hasLength(1),
            reason: 'one m.call.candidates event per batch, not per candidate');
        expect(session.call.batches.single, hasLength(3));
        expect(
            session.call.batches.single
                .map((candidate) => candidate['candidate'])
                .toList(),
            [
              contains('candidate:host'),
              contains('candidate:srflx'),
              contains('candidate:relay'),
            ]);
      });
    });

    test('nothing is sent before the invite went out, then the queue flushes',
        () {
      fakeAsync((async) {
        final session = _Session('pre-invite');
        unawaited(session.call.initOutboundCall(CallType.kVoice));
        async.flushMicrotasks();
        expect(session.call.state, CallState.kCreateOffer);

        // Candidates gathered while we still owe the peer an invite.
        session.gather('early');
        async.elapse(_historicalFirstBatchDelay);
        async.flushMicrotasks();
        expect(session.call.batches, isEmpty,
            reason: 'the remote peer has no SDP to attach them to yet');

        session.peer.onRenegotiationNeeded!();
        async.elapse(CallTimeouts.delayBeforeOffer);
        async.flushMicrotasks();
        expect(session.call.state, CallState.kInviteSent);

        async.elapse(CallTimeouts.firstCandidateFlush);
        async.flushMicrotasks();
        expect(session.call.batches, hasLength(1));
        expect(session.call.batches.single.single['candidate'],
            contains('candidate:early'));
      });
    });

    test('ice gathering complete flushes the held batch immediately', () {
      fakeAsync((async) {
        final session = _Session('gathering-complete');
        session.sendInvite(async);

        session.gather('held');
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(session.call.batches, isEmpty);

        session.gatheringComplete();
        async.flushMicrotasks();

        expect(session.call.batches, hasLength(1),
            reason: 'complete cancels the settle timer and sends now');
        expect(session.call.batches.single.single['candidate'],
            contains('candidate:held'));
      });
    });

    test('an ended call never flushes its pending batch', () {
      fakeAsync((async) {
        final session = _Session('ended');
        session.sendInvite(async);

        session.gather('pending');
        async.elapse(const Duration(milliseconds: 1));

        // Real terminate path: cleanUp() + the kEnded state transition.
        unawaited(session.call
            .terminate(CallParty.kLocal, CallErrorCode.userHangup, false));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(session.call.batches, isEmpty);
        expect(session.call.sendAttempts, isEmpty);
        expect(session.call.state, CallState.kEnded);
        expect(session.peer.closeCalls, greaterThan(0));
      });
    });

    test('a replaced call cannot send candidates through the new call', () {
      fakeAsync((async) {
        final oldSession = _Session('old');
        oldSession.sendInvite(async);
        oldSession.gather('old-host');
        // Old call has a batch armed on its settle timer.
        async.elapse(const Duration(milliseconds: 1));
        expect(oldSession.call.batches, isEmpty);

        unawaited(oldSession.call
            .terminate(CallParty.kLocal, CallErrorCode.replaced, false));
        async.flushMicrotasks();

        // Replacement call on its own peer connection.
        final newSession = _Session('new');
        newSession.sendInvite(async);
        newSession.gather('new-host');
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(oldSession.call.batches, isEmpty,
            reason: "the old call's timer must not fire after it was replaced");
        expect(newSession.call.batches, hasLength(1));
        expect(newSession.call.batches.single, hasLength(1));
        expect(newSession.call.batches.single.single['candidate'],
            contains('candidate:new-host'));
        expect(newSession.call.batches.single.single['candidate'],
            isNot(contains('old-host')),
            reason: 'no batch of the old call may leak into the new one');
      });
    });

    test('failed candidate sends give up on the call with iceTimeout', () {
      fakeAsync((async) {
        final session = _Session('give-up');
        session.sendInvite(async);
        // Every attempt fails.
        session.call.failNextSends(100);

        session.gather('doomed');
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();

        // 1 initial attempt plus CallTimeouts.candidateSendMaxTries retries:
        // the historical bound (tries > 5) must not be relaxed.
        expect(session.call.sendAttempts,
            hasLength(CallTimeouts.candidateSendMaxTries + 1));
        expect(session.call.batches, isEmpty);
        expect(session.call.hangupReasons, [CallErrorCode.iceTimeout]);

        // Bounded: no further attempt after giving up.
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(session.call.sendAttempts,
            hasLength(CallTimeouts.candidateSendMaxTries + 1));
      });
    });
  });

  group('CandidateSendQueue', () {
    test('the settle-window assertion is sensitive to the old 2000 ms delay',
        () {
      fakeAsync((async) {
        final sends = <List<RTCIceCandidate>>[];
        // Negative control: the same queue configured with the historical
        // unconditional delay must NOT have sent within the settle window.
        final queue = CandidateSendQueue(
          send: (batch) async => sends.add(batch),
          firstFlushDelay: _historicalFirstBatchDelay,
        );
        queue.onInviteOrAnswerSent();
        queue.add(_candidate('first'));

        async.elapse(CallTimeouts.firstCandidateFlush);
        async.flushMicrotasks();
        expect(sends, isEmpty,
            reason: 'this is exactly the behaviour the fix removes');

        async.elapse(_historicalFirstBatchDelay);
        async.flushMicrotasks();
        expect(sends, hasLength(1));
        queue.cancelAndDispose();
      });
    });

    test('retries a failed batch with exponential backoff without losing it',
        () {
      fakeAsync((async) {
        final attempts = <List<RTCIceCandidate>>[];
        final queue = CandidateSendQueue(send: (batch) async {
          attempts.add(batch);
          if (attempts.length <= 2) throw StateError('transport down');
        });
        queue.onInviteOrAnswerSent();
        queue.add(_candidate('keep-me'));

        async.elapse(CallTimeouts.firstCandidateFlush);
        async.flushMicrotasks();
        expect(attempts, hasLength(1));

        // First retry: retryBase * 2^1 = 1000 ms.
        async.elapse(const Duration(milliseconds: 999));
        async.flushMicrotasks();
        expect(attempts, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(attempts, hasLength(2));
        expect(attempts.last.single.candidate, contains('candidate:keep-me'),
            reason: 'a failed batch must not lose its candidates');

        // Second retry waits twice as long: retryBase * 2^2 = 2000 ms.
        async.elapse(const Duration(milliseconds: 1999));
        async.flushMicrotasks();
        expect(attempts, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(attempts, hasLength(3));
        expect(attempts.last.single.candidate, contains('candidate:keep-me'));

        // Success resets the failure counter and closes the retry chain.
        expect(queue.failedTries, 0);
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(attempts, hasLength(3));
        queue.cancelAndDispose();
      });
    });

    test('gives up after CallTimeouts.candidateSendMaxTries retries', () {
      fakeAsync((async) {
        final attempts = <int>[];
        final abandoned = <int>[];
        final queue = CandidateSendQueue(
          send: (batch) async {
            attempts.add(batch.length);
            throw StateError('transport down');
          },
          onSendAbandoned: abandoned.add,
        );
        queue.onInviteOrAnswerSent();
        queue.add(_candidate('doomed'));

        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();

        expect(attempts, hasLength(CallTimeouts.candidateSendMaxTries + 1));
        expect(abandoned, [CallTimeouts.candidateSendMaxTries + 1]);
        expect(queue.isClosed, isTrue);

        // After abandoning, even gathering complete or a new candidate cannot
        // produce another event.
        queue.add(_candidate('late'));
        unawaited(queue.onGatheringComplete());
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(attempts, hasLength(CallTimeouts.candidateSendMaxTries + 1));
      });
    });

    test('cancelAndDispose stops every pending timer forever', () {
      fakeAsync((async) {
        final sends = <List<RTCIceCandidate>>[];
        final queue =
            CandidateSendQueue(send: (batch) async => sends.add(batch));
        queue.onInviteOrAnswerSent();
        queue.add(_candidate('dropped'));
        async.elapse(const Duration(milliseconds: 1));

        queue.cancelAndDispose();
        queue.add(_candidate('after-dispose'));

        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(sends, isEmpty);
        expect(queue.pendingCandidates, 0);
      });
    });

    test('a send completing after the call was replaced schedules nothing', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        var attempts = 0;
        final queue = CandidateSendQueue(send: (batch) async {
          attempts++;
          await gate.future;
        });
        queue.onInviteOrAnswerSent();
        queue.add(_candidate('in-flight'));

        async.elapse(CallTimeouts.firstCandidateFlush);
        async.flushMicrotasks();
        expect(attempts, 1);

        // Call A is replaced while its batch is still on the wire.
        queue.cancelAndDispose();
        gate.complete();
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();

        expect(attempts, 1,
            reason: 'the closed queue may not retry or start another batch');
      });
    });

    test('queues candidates that arrive before the invite/answer was sent', () {
      fakeAsync((async) {
        final sends = <List<RTCIceCandidate>>[];
        final queue =
            CandidateSendQueue(send: (batch) async => sends.add(batch));
        queue.add(_candidate('early'));

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(sends, isEmpty);

        queue.onInviteOrAnswerSent();
        async.elapse(CallTimeouts.firstCandidateFlush);
        async.flushMicrotasks();
        expect(sends, hasLength(1));
        expect(sends.single.single.candidate, contains('candidate:early'));
        queue.cancelAndDispose();
      });
    });

    test('later batches coalesce inside the batch window', () {
      fakeAsync((async) {
        final sends = <List<RTCIceCandidate>>[];
        final queue =
            CandidateSendQueue(send: (batch) async => sends.add(batch));
        queue.onInviteOrAnswerSent();

        queue.add(_candidate('first'));
        async.elapse(CallTimeouts.firstCandidateFlush);
        async.flushMicrotasks();
        expect(sends, hasLength(1));

        queue.add(_candidate('second'));
        async.elapse(const Duration(milliseconds: 20));
        queue.add(_candidate('third'));
        async.elapse(CallTimeouts.candidateBatchWindow);
        async.flushMicrotasks();

        expect(sends, hasLength(2));
        expect(sends.last, hasLength(2));
        queue.cancelAndDispose();
      });
    });
  });
}
