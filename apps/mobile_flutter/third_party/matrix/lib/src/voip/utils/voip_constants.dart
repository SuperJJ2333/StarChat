import 'package:matrix/matrix.dart';

/// https://github.com/matrix-org/matrix-doc/pull/2746
/// version 1
const String voipProtoVersion = '1';

class CallTimeouts {
  /// The default life time for call events, in millisecond.
  static const defaultCallEventLifetime = Duration(seconds: 10);

  /// The length of time a call can be ringing for.
  static const callInviteLifetime = Duration(seconds: 60);

  /// The delay for ice gathering.
  static const iceGatheringDelay = Duration(milliseconds: 200);

  /// ChatFlow (Task O): how long an ICE `disconnected` state is tolerated
  /// before an ICE restart is attempted. Mobile networks flap
  /// (Wi-Fi -> LTE and back) within a few hundred milliseconds; escalating a
  /// short blip straight to `restartIce()` (or worse, ending the call) made a
  /// brief drop look like "network interrupted". Bounded on purpose: the
  /// connection is never kept alive on hope for tens of seconds.
  static const iceDisconnectedGrace = Duration(seconds: 3);

  /// ChatFlow (Task O): maximum `restartIce()` attempts per call before the
  /// call is ended with [CallErrorCode.iceFailed]. Reached only after
  /// [iceDisconnectedGrace] windows on the `disconnected` path.
  static const maxIceRestarts = 3;

  /// Settle window applied to the **first** candidate batch that is sent after
  /// `m.call.invite` / `m.call.answer` was published.
  ///
  /// MSC2746 has no trickle ICE, so candidates must still be coalesced into one
  /// `m.call.candidates` event instead of being sent one by one. The local
  /// candidates are, however, usable by the peer as soon as it has our SDP, so
  /// the first batch is only held back for this short beat. The previous
  /// unconditional 500 ms (incoming) / 2000 ms (outgoing) wait sat directly on
  /// the `answerSent -> iceConnected` critical path and delayed media setup.
  ///
  /// https://github.com/matrix-org/matrix-doc/pull/2746
  static const firstCandidateFlush = Duration(milliseconds: 150);

  /// Coalescing window for every candidate batch after the first one. Several
  /// candidates arriving inside the same window are published in a single
  /// `m.call.candidates` event; a single candidate never causes a request.
  static const candidateBatchWindow = Duration(milliseconds: 200);

  /// Fallback flush while `iceGatheringState` is still `gathering`: whatever has
  /// been gathered so far is sent even when no further state transition arrives.
  /// Because trickle ICE is unsupported (MSC2746), gathering must never be the
  /// only thing that keeps the peer waiting for connectivity.
  static const iceGatheringFallback = Duration(seconds: 3);

  /// Base delay of the exponential backoff applied to a failed
  /// `m.call.candidates` send: `retryBase * 2^attempt`.
  static const candidateSendRetryBase = Duration(milliseconds: 500);

  /// Number of retries of a failed `m.call.candidates` batch before the call is
  /// given up with `CallErrorCode.iceTimeout`. This mirrors the historical bound
  /// and must not be raised to hide send failures.
  static const candidateSendMaxTries = 5;

  /// Delay before createOffer.
  static const delayBeforeOffer = Duration(milliseconds: 100);

  /// How often to update the expiresTs
  static const updateExpireTsTimerDuration = Duration(minutes: 2);

  /// the expiresTs bump
  static const expireTsBumpDuration = Duration(minutes: 6);

  /// Update the active speaker value
  static const activeSpeakerInterval = Duration(seconds: 5);

  // source: element call?
  /// A delay after a member leaves before we create and publish a new key, because people
  /// tend to leave calls at the same time
  static const makeKeyDelay = Duration(seconds: 4);

  /// The delay between creating and sending a new key and starting to encrypt with it. This gives others
  /// a chance to receive the new key to minimise the chance they don't get media they can't decrypt.
  /// The total time between a member leaving and the call switching to new keys is therefore
  /// makeKeyDelay + useKeyDelay
  static const useKeyDelay = Duration(seconds: 4);
}

class CallConstants {
  static final callEventsRegxp = RegExp(
      r'm.call.|org.matrix.call.|org.matrix.msc3401.call.|com.famedly.call.');

  static const callEndedEventTypes = {
    EventTypes.CallAnswer,
    EventTypes.CallHangup,
    EventTypes.CallReject,
    EventTypes.CallReplaces,
  };
  static const omitWhenCallEndedTypes = {
    EventTypes.CallInvite,
    EventTypes.CallCandidates,
    EventTypes.CallNegotiate,
    EventTypes.CallSDPStreamMetadataChanged,
    EventTypes.CallSDPStreamMetadataChangedPrefix,
  };

  static const updateExpireTsTimerDuration = Duration(seconds: 15);
  static const expireTsBumpDuration = Duration(seconds: 45);
  static const activeSpeakerInterval = Duration(seconds: 5);
}
