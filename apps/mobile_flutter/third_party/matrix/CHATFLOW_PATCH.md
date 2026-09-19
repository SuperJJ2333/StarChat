# ChatFlow integration patch on Matrix 0.34.0

Upstream package: matrix 0.34.0, existing locked dependency from pub.dev mirror.
Original LICENSE and attribution retained. Vendored lib tree is unchanged except
`lib/src/voip/call_session.dart`, `lib/src/timeline.dart`, and the attachment
preparation changes documented below; see the source hashes
in the verification records.

Incoming 1:1 invite initialization used to acquire camera/microphone before
VoIP delivered the call to the application. Missing permission threw before any
incoming UI could be presented. Local media capture is now deferred to answer(),
which the application calls after explicit media permission consent. Outgoing
capture, group-call stream flow, signaling payloads and encryption are unchanged.

Answer preparation coalesces concurrent requests, preserves ringing on media
acquisition failure, and disposes media arriving after call termination. Four
existing fire-and-forget futures are explicitly marked unawaited and an existing
single-line conditional is braced to satisfy the retained upstream analyzer
configuration; these are not behavioral protocol changes.

Regression tests live in the application:
`test/features/matrix/incoming_sdk_media_test.dart`, plus controller/UI/native
permission-recovery tests. Do not replace this local dependency with stock 0.34.0
without re-running the missing-permission regressions. On upstream upgrades,
review whether the fix is upstreamed, rebase the minimal diff and record its
provenance; do not edit a developer pub-cache as the only persistent fix.

2026-09-07 timeline ordering: a synced event must not be replaced by a late
local sending/sent/error update. The previous merge kept the synced status but
replaced the server timestamp and payload with local data when /sync arrived
before the HTTP send acknowledgement. Ignore those lower-authority updates;
subsequent synced updates still apply normally. The change does not modify
transport, encryption or outgoing payloads. Real Timeline stream regressions:
`test/features/matrix/sdk_ack_order_test.dart`.

2026-09-09 content-addressed attachments (ADR-0060):

- `lib/src/utils/crypto/encrypted_file.dart` exports `encryptFileWithKey` with
  explicit 32-byte AES key and 16-byte IV validation, standard Matrix v2
  unpadded encodings and SHA-256 of ciphertext. Random `encryptFile` remains.
- `lib/src/utils/matrix_file.dart` accepts an optional `preEncrypted` envelope
  on every concrete media type. `bytes`, MIME, size, image dimensions, blurhash,
  video dimensions/duration and audio duration remain plaintext preview metadata;
  `encrypt()` returns the same prepared envelope on retries.
- `lib/src/room.dart` refuses prepared attachments without file E2EE and skips
  image/thumbnail transformation for a prepared original. The application must
  finish body transformations and thumbnail generation before preparation.
  Upload uses only the envelope ciphertext, filename `crypt`, and octet-stream
  MIME; content hashes exist only in the subsequently encrypted room event.

Application regressions: `test/features/matrix/content_addressed_media_test.dart`
exercises independent HKDF vectors, standard SDK decryption, actual
`Room.sendFileEvent` ciphertext uploads, retry identity, media metadata,
preprocessing order, decrypted-event authority and validated content caches.
This patch does not change Megolm rotation, room encryption or avatar uploads.

2026-09-12 sync-loop ownership recovery:

- `lib/src/client.dart` assigns each SDK sync loop a monotonically increasing
  generation. `abortSync()` invalidates the active generation before its
  asynchronous cleanup. Generation checks run before retry/filter/request
  work, after transaction processing, and before error side effects. A late
  request from an older generation cannot clear a replacement `_currentSync`,
  start another background loop, issue a stale retry request, publish any
  status, or process a stale unknown-token logout. `processing` is reported
  only after a non-null response owned by the current loop. This changes
  sync-loop bookkeeping only; Matrix E2EE, key
  handling, room-event processing, and transport payloads are unchanged.
- Application regression `test/features/matrix/matrix_sync_recovery_sdk_test.dart`
  uses a real vendored `Client` with held fake HTTP `/sync` futures. It covers
  late success and unknown-token error replies after `abortSync()` and a
  replacement request while background sync is enabled, a late reply after
  disposal, and an aborted loop held behind the shared retry delay.
- Chronology: the generation guard existed before this regression was added.
  The test was therefore written after the initial implementation. Its RED
  evidence was reconstructed by temporarily restoring only this vendor sync
  hunk, running the held-response test, and restoring the hunk before GREEN.
  Raw commands, output, and actual exit codes are in
  `docs/verification/artifacts/2026-09-12/offline-recovery/`.

2026-09-12 fragmented history availability:

- `Timeline.canRequestHistory` now uses the fragmented timeline's own
  `chunk.prevBatch`. An exhausted context does not inherit the live room's
  unrelated backward token; a context with a token remains loadable even when
  the live room has no backward token. The existing live-timeline branch is
  unchanged. A room-create event remains a terminal boundary.
- Regression: `test/features/matrix/sdk_history_fragment_test.dart` exercises
  the real Timeline getter with exhausted and available context tokens.
  Astra's focused SDK/adapter/RoomPage verification is recorded at
  `docs/verification/artifacts/2026-09-12/history-latency/sdk-fragment-final-focused.log`.
- This small prerequisite does not implement calendar timestamp lookup or
  forward context navigation. Those application changes remain pending in
  `docs/superpowers/plans/2026-09-12-history-latency.md`.

2026-09-13 fragmented history lifecycle:

- `Timeline.requestFuture` always clears its in-flight flag, including after a
  transport failure, so a context fragment can retry its forward page.
  Limited live sync updates no longer clear a fragmented context timeline.
- While a fragment blocks unrelated live appends, authoritative updates and
  redactions for events it already contains still apply. Existing Matrix
  request/decryption and key-management paths are unchanged.
- Regression: `test/features/matrix/sdk_history_fragment_test.dart` uses the
  real Timeline with a mocked Matrix transport plus real client event/sync
  streams for retry, limited-sync, update, redaction, and live-append bounds.

2026-09-13 fragmented history request ownership:

- Backward and forward page requests are mutually exclusive per Timeline.
  They share the chunk and `_collectHistoryUpdates` collector, so a caller
  arriving while either direction is in flight returns without transport and
  may retry after the owner completes. This does not alter Matrix request
  payloads, encryption, or token handling.
- Regression: `test/features/matrix/sdk_history_fragment_test.dart` holds a
  real backward HTTP request, confirms a concurrent forward call emits no
  second request, then confirms the explicit retry succeeds after release.

2026-09-17 ICE candidate flush latency:

- New `lib/src/voip/utils/candidate_send_queue.dart` owns the local candidate
  batching for one `CallSession`; `lib/src/voip/call_session.dart` hands
  `pc.onIceCandidate` to it and wires the invite/answer, gathering-complete and
  teardown transitions. MSC2746 has no trickle ICE, so candidates are still
  coalesced into `m.call.candidates` events, but the first batch after
  `m.call.invite` / `m.call.answer` now leaves after
  `CallTimeouts.firstCandidateFlush` (150 ms) instead of the previous
  unconditional 2000 ms (outgoing) / 500 ms (incoming) wait, which sat on the
  `answerSent -> iceConnected` critical path. Later batches use
  `CallTimeouts.candidateBatchWindow`; `iceGatheringState == complete` flushes
  immediately and cancels the (previously uncancellable) 3 s gathering
  fallback. The `500 ms * 2^tries` retry backoff and the
  `tries > 5 -> hangup(iceTimeout)` bound are unchanged, and a failed batch no
  longer loses its candidates. Pending timers are cancelled in `cleanUp()`,
  on `kEnded`, and when a peer connection is prepared for a replacement call.
  SDP/answer/negotiate payloads are unchanged.
- Regression: `test/features/matrix/call_candidate_flush_test.dart` drives the
  real `CallSession` signalling path with `fake_async` and faked transport/peer
  edges (first-batch latency, coalescing, pre-invite queueing, gathering
  complete, ended/replaced call, `iceTimeout` give-up) plus the extracted
  `CandidateSendQueue` unit (backoff, give-up bound, dispose, cross-call
  generation, and a negative control proving the assertion detects the old
  2000 ms delay).

2026-09-19 stale-send self-heal re-entrancy (Mi 6 ANR):

- `lib/src/event.dart` no longer re-enters `Client.handleSync` every time a stale
  `sending` event is reconstructed. The previous self-heal fired on *every*
  construction of an event whose status is `sending` and whose age exceeds
  `Client.sendTimelineEventTimeout`, and sync handling itself reconstructs events
  while it persists them (`MatrixSdkDatabase.storeEventUpdate` builds the previous
  row as an `Event` at `matrix_sdk_database.dart:1063`). One row left in
  `sending` therefore pumped `Client.handleSync` without bound, entirely locally:
  device instrumentation measured ~1,380 stream deliveries/s and ~21,000
  callbacks/s sustained for 90+ s on the Dart UI isolate, the 1 s timer queue
  stopped firing entirely, no frame was produced, and input dispatch died (the
  ANR "畅聊 ChatFlow没有响应", reproduced on 0.3.95/2133 debug, 0.3.96/2134 debug and
  0.3.96/2134 release). The self-heal is now claimed at most once per
  `<roomId>\u0000<eventId>` per timeout window (`Event._claimStaleSendHeal`,
  bounded to 512 entries). Behaviour is otherwise unchanged: the same event is
  still re-injected, still marked `EventStatus.error`, and still persisted
  through the same sync path - it simply cannot do so repeatedly from inside its
  own reconstruction. Matrix request payloads, E2EE, key handling and the
  remaining event-processing paths are untouched.
- Regression: `test/features/matrix/sdk_stale_send_selfheal_test.dart` drives the
  real vendored `MatrixSdkDatabase` on an in-memory sqflite database, seeds one
  stale `sending` event, reconstructs `Event`s the way the persistence path does,
  and asserts that `Client.onSyncStatus` - which `Client._handleRooms` writes once
  per processed room - observes at most one sync run. RED evidence: with the guard
  bypassed the same test never completes (it was killed at the 600 s cap) because
  the reconstruction storm starves the event loop, which is the production
  failure itself; with the guard it passes in under a second. Device-level
  verification is recorded in `docs/verification/2026-09-19-mi6-anr-forensics.md`.
2026-09-19 bounded HTTP send lifecycle (weak-network room paralysis):

- `lib/src/utils/http_timeout.dart` now applies its timeout to
  `inner.send(request)` itself, not only to the response body stream. Before,
  a black-holed connection (TCP established, gateway silently dropping
  packets) could hang `inner.send()` forever; because every
  `Room.sendEvent` waits for the head of `Room._sendingQueue`
  (`room.dart:1069-1073`), one hung send permanently blocked all later sends
  of that room - and `Room` objects live in `client.rooms` across page
  navigation, so only killing the process recovered it. With the timeout, the
  retry loop's own `timeoutDate` check is guaranteed to run and the request
  fails as a network error within the configured window.
- The application additionally tightens `Client.sendTimelineEventTimeout`
  from 1 minute to 20 s (composition root) so text sends surface their
  failure (typed `MessageSendNetworkException` -> red exclamation + automatic
  resend on recovery) promptly instead of queueing behind a one-minute serial
  retry window. The `event.dart` stale-send self-heal window follows the same
  field and therefore heals earlier; its once-per-window claim is unchanged.
- Transport, encryption, key handling and outgoing payloads are untouched.
- Regression coverage lives in the application:
  `test/features/matrix/offline_send_state_test.dart` (offline fast-fail and
  hung-dispatch guard) and `test/core/network_state_manager_test.dart`
  (typed exception classified as network failure).
