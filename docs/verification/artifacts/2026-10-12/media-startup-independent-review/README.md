# AppHome media startup: independent source review

Decision: **APPROVE_SOURCE_FOCUSED_ONLY** for `ccd45e8e28f5110d852a2f46a568a1635f9a457f`, baseline `0ef24bd100b9f96760e7a6be2ef01c40c900e05c`. No blocking specification or quality/security finding. This decision is not an APK, device, SQLCipher, network ACK, rollout or complete regression approval.

## 1. Specification / domain review — performed first

The only runtime change moves `_startup.open()` and `_matrixReady = true` ahead of `_bindConnectionStatus()` at `apps/mobile_flutter/lib/app_home.dart:1930–1934`. The synchronous chain is connection status → network state → outbox → async media binding. `_bindMediaOutbox` captures `_startup.generation` before its first secure-store await (1772); the old order captures generation 0 and then increments it to 1. Its correct current-owner check therefore rejects the result when the await completes. This explains the same pre-upload `owner-unavailable` failure for both public prepared-image and gallery-video paths in the composition reproduction. It does not independently prove that every reported phone has only this cause.

The new order gives the binding the opened generation. It does not remove or relax any guard, create a fallback sender, alter storage/codec/native/dependencies, change Matrix encryption or give business APIs communication plaintext. Existing R8 persist-before-admission, account isolation and transactional media-send boundaries remain unchanged. Financial behavior, authentication and protocol are outside this diff.

Author fixed-lock RED evidence is verified: original source `2314168d362c2dd269cbd7bceb378ce10a41a5da004cfc51bf71284ee2fa6835` plus the final new test yields 2 PASS / 5 intended FAIL, including image/video `owner-unavailable`. The independent GREEN below exercises the actual AppHome composition root and public Matrix enqueue entry points, not an imitation of the reordered statements.

## 2. Quality / security review — performed after specification review

No blocking finding. Static review and an additional independent static reviewer agreed on these preserved properties:

- `app_home.dart:1774–1788`: after binding resolves, mounted/disposed, startup generation/readiness, binding epoch, Matrix instance, account and send-preparation identity remain required; the binding account and homeserver must match.
- `app_home.dart:2933`: close revokes `_matrixReady` synchronously before asynchronous cleanup; startup close later increments generation. `dispose:2908` sets `_disposed`, and outbox cleanup at 1821 advances the binding epoch and suspends the service. A late callback cannot install a sender after either path.
- `app_home.dart:1828`: cleanup clears the shared service only when it owns that exact instance. It cannot erase another instance merely because close finishes late.
- `matrix_e2ee_client.dart:6714–6736`: both bind and send retain active-owner/account/homeserver/send-identity checks. Managed clients without the durable binding still fail closed with `owner-unavailable`. The service also rechecks active ownership after authorization awaits.
- The new startup order neither adds an await nor changes the notification bootstrap scheduling. Existing lifecycle tests cover immediate removal, delayed initialization draining, native-revoke failure cleanup, shell rendering, watchdog start/state/unbind and nonblocking group entry.

The composition test uses real temporary files, desktop SQLite durable rows and secure-binding serialization. Matrix Room transport, native private-directory metadata and video codec are explicit doubles. The fixture returns synthetic business HTTP 404 and catches optional notification/call LateError/disposal diagnostics; the raw log retains these. They are not evidence of native notification/call disposal or successful production network traffic.

Unmeasured boundaries remain: same-account detach/reopen with old/new binding interleavings, invalid/null/foreign-homeserver binding at the composition root, real logout/login replacement, actual mobile SQLCipher and native codecs, and server ACK/receiver visibility. Static guards cover the unchanged failure paths; these are not represented as newly executed device cases. Root owns actual debug installation/sending and final candidate gates.

## Independent evidence and identity

- Exactly the two candidate mobile files were exported from Git into this isolated review checkout. All other mobile tracked inputs already matched the candidate. The 1,620-file lib/test/third_party/config closure matched candidate content (existing CRLF representation allowed), and all raw hashes stayed unchanged across the run. The original checkout files were restored afterward; mobile Git status is clean.
- `flutter pub get --offline --enforce-lockfile` with `PUB_HOSTED_URL=https://pub.dev` passed. All 216 hosted package versions match the fixed lock; no package mismatch. Lock SHA: `a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d`.
- Independent `flutter test --no-pub test/app_home_media_outbox_startup_test.dart test/app_home_lifecycle_test.dart --reporter expanded`: **14 PASS / 0 FAIL**, exit 0. UTC 2026-10-12T12:00:47.9601437Z–12:00:56.7586172Z (8.7985 seconds).
- AppHome SHA: `54c01b0f2a090a19d26690d84d951653dbf8173311ed098bb343a1b8c8e466bf`.
- New test exact Git/LF SHA: `ff11c524ab84b39cb0f347a67c870d9af3ee591e2b08d165635ef886e949997c`; author Windows raw SHA `38651f0c11c83dec36d625c2728015315cd27107c3703eae595527a10a4b46ea` differs only by CRLF. This reconciliation does not change either frozen input.
- All 14 author archive-hash entries match both actual bytes and candidate Git blobs. Author fixed-lock analyze and seven desktop SDK/coordinator neighbor tests are reviewed/reused, not counted as independent executions. The broader old full regression was not repeated.
- Two reviewer preflight script errors (CRLF parsing and an absent guessed vendor archive path) stopped before tests and were corrected in the reviewer only. No candidate source or timeout/assertion was changed.

Evidence: [focus log](focused.log), [focus command/timing](focused-receipt.json), [input closure](input-identities.json), [author/after-run checks](after-run-and-author-evidence.json), [export](export-receipt.json), [restore](restore-receipt.json), [dependency log](pub-get.log), [dependency receipt](pub-get-receipt.json), [Flutter version](flutter-version.json).

This review changes only its own verification directory. No root/product change, signing, ADB, remote access or deployment occurred. Exact review-phase active timing was not captured and is not inferred; command timings above are recorded. Next step: root integrates the candidate and this evidence, then completes actual debug and final-candidate gates without treating this source result as phone acceptance.
