# ChatFlow integration patch on Matrix 0.34.0

Upstream package: matrix 0.34.0, existing locked dependency from pub.dev mirror.
Original LICENSE and attribution retained. Vendored lib tree is unchanged except
`lib/src/voip/call_session.dart`; see the source hashes in the verification record.

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
