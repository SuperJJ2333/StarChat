# Independent review: shared object demand and playback preparation

Reviewed frozen commit `34d1263ceb53b8f9e3efe703e548aa58de82dd5e`, parent `c3c66fbc4e5d779751368f0c9bce03bb5de8fd04`, underlying `44dabcc9d6428e38adfe93f572deeec0c64e8653`. Reviewer backend_review; own tree `C:/Users/Administrator/.codex/worktrees/im-media-cache-review/StarChat`; date 2026-10-11. Product files unchanged by reviewer; synthetic local tests only, no device/server/deployment action.

## Stage 1 — SPEC/domain

The shared-object demand correction PASSES its independently verified scope. Each already verified source registers dynamic demand; atomic object/length writes use the union under a separate captured account/global generation fence. Canceled A cannot veto active B, and all-consumer cancellation still prevents pending publication. Each registration remains until the real object Future settles, and map retirement checks identity. References/index/memory continue in each source's original Zone. Removing the redundant whole-store digest shortcut permits same-event/different-source registrations while retaining every synchronous unique preparation entry for playback/clear.

The four unchanged independent probes, five publication cases, and four owned object-join cases pass independently (13 PASS, exit 0). The owned object probe explicitly excludes `.len.` to intercept the actual object temporary write and asserts one physical write, two 4096-byte reservations held to settlement, no canceled-source reference, live-source reference, and no object when all demand disappears. The same-event case exercises removal of the whole-store shortcut. An additional reviewer variant sends B through the actual public `resolveCachedVideoFile(loaderCachesContent: true)` flow; all four object-join scenarios pass (4 PASS, exit 0).

However, complete candidate acceptance is NOT PASS because the following pending-preparation window remains broken.

### P2 — Canceled independent preparation fails playback of an already valid same-reference cache

Evidence locations: `apps/mobile_flutter/lib/features/matrix/media_cache.dart:648` stores each preparation Future, `:650` removes it only on settlement, `:801` snapshots them with raw `Future.wait`, and `:1919` invokes this wait from the public playback resolver. Actual product entry: `apps/mobile_flutter/lib/features/matrix/room_page.dart:2319`, with `loaderCachesContent: true` and its attachment loader.

Reproduction uses one synthetic account, same room/event, different legacy source descriptors, no advertised content digest, and equal real verified bytes:

1. Source A reaches real post-verification store-root preparation and blocks in the path-provider Future. Its unique preparation is registered synchronously. Cancel A's observer while its real source remains alive and budget stays reserved.
2. Independent B enters `resolveCachedVideoFile` with the same parameters as the RoomPage entry. Its loader calls the real `loadMediaWithCache`. B completes its source, verified object, reference and index work. Its reference already reads back the expected bytes. Only A retains a real source reservation.
3. B's final indexed-cache verification reads the real file stream; a Timer scheduled after stream completion ensures the `_valid/cached` microtasks have unwound into `preparePlaybackFile`'s synchronous wait set. This includes still-pending A. B remains active and has not completed playback.
4. Release A's root Future. A's own publication check correctly rejects its canceled demand. That `MediaLoadCanceled` escapes `Future.wait` and rejects B's public playback result although B's own reference is valid.

Definitive independent probe: `docs/verification/artifacts/2026-10-11/im-media-cache-independent-review/playback-preparation-cancel_test.dart`. Log: `34d-playback-preparation-cancel-r3.log`. Control without A cancellation PASS; A cancellation FAIL; exit 1. Both branches settle real source/budget work and clean fixtures. This does not rely on a direct artificial call to `preparePlaybackFile`; it enters through `resolveCachedVideoFile`. It is a remaining P2 acceptance failure of this candidate, not a claim that 34d newly introduced it relative to c3. No production incidence or cross-account disclosure is asserted.

The already-passing object-barrier scenarios have a different timing: A settles/cleans its preparation before B completes its reference/index work, so B's later preparation snapshot cannot see A's failure. They do not cover A remaining stuck before object registration while B independently completes the same reference.

Minimum follow-up: retain waiting for actual preparation settlement, but prevent another canceled preparation from rejecting playback when the requested reference independently validates successfully. Preserve global/account-generation checks and integrity validation. Do not blindly swallow arbitrary store errors, return an unverified file, release resource reservations early, or remove synchronous preparation tracking. Add explicit missing/corrupt-cache and non-cancellation error controls for any changed error policy, then independently re-review.

## Stage 2 — QUALITY/security

NOT APPROVED for integration until the playback preparation P2 is closed. No separate security blocker was found in the new `_MediaObjectFlight` implementation: account-local path identity and authenticated byte proofs remain required; cancellation is the only suppressed per-source guard exception; generation/state errors still fail. Lifetime cleanup and own-source publication checks remain explicit. The first phase's new failure was discovered after the initial object-specific checks passed, so earlier progress messages are not a final candidate approval.

No scheduler, crypto, financial, authentication, native or schema behavior changed. The integration still needs the parent's shared full/native gates with its newer SQLCipher factory, because this isolated branch does not contain those root changes.

## Evidence correction and reuse

The previous review report at commit `74c20c72b10e02fb4f277e96383c52dee86e73c1` described its original `startsWith('$target.')` file barrier as an object temporary-file flush. That prefix also matches the earlier `$target.len.<uuid>.tmp`: the actual barrier was the length sidecar flush. This corrects that description. The 44dab/c3 behavioral difference remains real. The prior cancellation propagation finding did not depend on which of the object's governed publications was blocked. The author preserved the original probe unchanged, corrected its owned barrier to exclude `.len.`, and separately demonstrated the failure at the actual object flush.

All six source/fixture identities and six archived logs in the author's `object-join-input-identities.json` match their normalized SHA values (12 checks). The copied independent object probe exactly matches the prior review commit after LF normalization. The archived 97-case adjacent run and analyzer-zero evidence are reused for those frozen inputs; they are not claimed as rerun here, and overlapping case counts are not added.

Independent review artifacts under `docs/verification/artifacts/2026-10-11/im-media-cache-independent-review/`:

| Evidence | Result |
| --- | --- |
| 34d-publication-13.log | 13 PASS, exit 0; command wall time 6.99 seconds |
| playback-object-join_test.dart + 34d-playback-object-join.log | Four public-playback variants, 4 PASS, exit 0; 5.10 seconds |
| playback-preparation-cancel_test.dart + 34d-playback-preparation-cancel-r3.log | Strong final I/O barrier; 1 PASS / 1 FAIL, exit 1; 6.07 seconds |
| 34d-review-identities.json | Reviewed inputs, log/probe SHA identities and UTC timestamps |

The initial preparation variant merely waited for B's resource settlement and could release A before B entered its preparation snapshot; its 2 PASS does not establish this narrower boundary. Subsequent harness attempts had a nullable Future compile error and an IOOverrides wrapper missing `File.open`; those failures are not product findings. The definitive r3 probe forwards the real file operations and uses the actual indexed-read completion barrier. The repeated known MediaIndex fallback message is the existing negative-provider fixture, not an ignored product regression.

Next executable step: author reproduces the unchanged r3 probe, fixes only preparation error ownership while retaining cache verification and settlement, proves RED to GREEN with negative controls, and freezes an incremental commit for SPEC/domain then QUALITY. No server query, duplicate full-suite run, package publication or deployment is needed to resolve this review.
