# Integrated media test contract correction

Owner: review_r1_r2. Parent authorized isolated investigation/fix of the two complete-Flutter failures at integration 9902d350. Worktree: im-media-outbox/StarChat. Scope: matrix_client_factory_test.dart, matrix_room_media_ui_test.dart, and the inaccurate media-entry comment in matrix_e2ee_client.dart. No executable production change, dependency/configuration change, deployment, or build.

## Root cause and boundaries

The factory test required raw mutable Uint8List identity for original, thumbnail, and GIF. R7b deliberately establishes a worker-owned immutable snapshot and registers its private account/epoch-bound proof. Reusing the caller's mutable alias would invalidate that proof. The corrected test asserts exact content, distinct raw identity, no changes after caller mutation, and rejection of writes to the snapshot and thumbnail buffer. Existing proof tests separately cover account/epoch isolation and digest reuse. The public entry comment now describes this ownership accurately.

Root's complete-suite forward failure is line 537 (drained false), after the download already started. On unchanged 9902d350, our isolated pair was 82 PASS / 1 FAIL: only the identity assertion failed; forward passed. Thus the root's full-load forward failure is not misrepresented as an independently reproduced product fault. Adding a controlled real 1500 ms target settlement to the original approximately 1 second polling deadline reproduces the identical drained-false assertion. The exact probe diff and log are retained. The deadline was measuring real worker/cache/transport completion with a fixed polling count.

The final widget test exposes send-start and settlement Futures. After the source lease is revoked and its page is removed, it advances real I/O and FakeAsync until the target actually starts, then verifies that drain stays pending through two seconds of virtual time while the real target is held. Only explicit settlement allows drain and the one sent transaction to complete. A 30 second real-clock watchdog fails a hung test; it never releases/cancels production ownership. The helper propagates the milestone's actual error. Simply awaiting these Futures inside runAsync starved FakeAsync continuations; that failed intermediate experiment is preserved and is not counted as GREEN or product RED.

No changes to encryption, permission/account admission, transport lifecycle, coordinator, cache/quota, or byte budgets. The UI case uses the existing unmanaged SDK owner with real envelope/cache work and mocked HTTP/target event acceptance; it is not native device or live Matrix acceptance. Managed durable/native behavior remains covered by the separately frozen outbox gates, not claimed by this test.

## Fresh gates

All commands used PowerShell 7 with UTF8NoBOM console/pipeline and Python UTF-8 variables. Working directory apps/mobile_flutter, Flutter 3.44.9 / Dart 3.12.2; pubspec.lock unchanged. `--reporter expanded` used for test logs.

- Baseline: `flutter test --no-pub test/features/matrix/matrix_client_factory_test.dart test/features/matrix/matrix_room_media_ui_test.dart`: exit 1, 82 PASS / 1 FAIL. integrated-media-red.txt.
- Controlled old deadline: same UI file with `--plain-name 'RoomPage forwards held encrypted media'`: exit 1, 0 PASS / 1 FAIL. integrated-forward-deadline-red.txt and matching .patch.
- Intermediate wait experiment: exit 1, 82 PASS / 1 FAIL; integrated-media-fakeasync-attempt.txt. FakeAsync waits are not counted as an implementation regression.
- Final two complete files, same command as baseline: exit 0, 83 PASS / 0 FAIL / 0 SKIP. integrated-media-green.txt.
- Adjacent: `flutter test --no-pub test/features/matrix/verified_media_content_test.dart test/features/matrix/content_addressed_media_test.dart test/features/matrix/video_forward_backend_test.dart test/features/matrix/matrix_media_upload_limit_test.dart`: exit 0, 66 PASS / 0 FAIL / 0 SKIP. integrated-media-adjacent.txt. Includes immutable proof, account/epoch, full envelope/content integrity, encrypted forwarding and upload limits.
- `dart analyze lib/features/matrix/matrix_e2ee_client.dart test/features/matrix/matrix_client_factory_test.dart test/features/matrix/matrix_room_media_ui_test.dart`: exit 0, No issues found. integrated-media-analyze.txt.
- `git diff --check`: clean for source changes; raw failure logs/patch are kept exact.

The repository verify.ps1 exists; parent owns the integrated monorepo/full-Flutter gate. Per mobile workflow change-impact reuse, this test/comment-only correction does not repeat a monorepo gate or native builds in the subagent tree. This is not a full-suite PASS claim.

## Evidence identity, timing, next step

Input and log SHA-256 values, baseline commit, results and observable file timestamps are in integrated-media-input-hashes.json. Observed baseline log interval 06:47:50–06:48:08 UTC; final log last write 06:53:25; analyze 06:54:31–06:54:37; adjacent 06:54:31–06:54:42. File creation times can survive rename/overwrite and are not exact command start times. Active investigation time is not measured independently. No background process remains after final gates.

Independent SPEC/domain then QUALITY review is delegated to media_identity_review, report integrated-media-review.md. Next executable step: freeze this small commit after review, parent cherry-pick onto the integrated candidate, then complete the parent-owned shared gate. Rollback reverts test/comment changes only and does not alter stored data or production behavior.
