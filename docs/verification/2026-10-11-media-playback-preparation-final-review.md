# Final independent incremental review: playback preparation cancellation

Date: 2026-10-11. Non-author reviewer: backend_review. Exact reviewed implementation: `766784770e04d168b0ebc64bf4647051d0db2473`, parent `34d1263ceb53b8f9e3efe703e548aa58de82dd5e`. Own review tree: `C:/Users/Administrator/.codex/worktrees/im-media-cache-review/StarChat`. No product file was edited by the reviewer, and no device/server/deployment operation was performed.

## Stage 1 — SPEC/domain: PASS

The remaining playback failure in independent review `d111a29571c9c5d7ab74abf59560db886bfd2d00` is closed on the exact candidate. The unchanged public `resolveCachedVideoFile(loaderCachesContent: true)` probe now passes both control and canceled-A cases. B remains active, its reference is independently verified, and the older canceled A preparation no longer rejects valid playback.

Only `MediaCache.preparePlaybackFile` production behavior changes in this increment (`apps/mobile_flutter/lib/features/matrix/media_cache.dart:798`). Its wait set still contains every matching real preparation registered before hashing. Each awaited preparation captures only `MediaLoadCanceled`; non-cancellation errors propagate through non-eager `Future.wait`, so all matching work still settles. An early cancellation can no longer mask a later genuine I/O failure. Source ownership, reservations, object-flight aggregation and per-source reference publication are unchanged.

The request captures its own consumer scope and global/account epochs. Checks run before the wait, after settlement, and after the existing integrity-verifying `cached` lookup. A valid file is accepted only for a still-current request. If no valid file remains, the captured cancellation and stack are rethrown; a cache miss with no captured cancellation retains its prior FileSystemException. This is not a blanket error suppression or an unverified cache fallback.

Independent focused command from `apps/mobile_flutter`:

`flutter test --no-pub --reporter expanded test/features/matrix/media_playback_preparation_test.dart ../../docs/verification/artifacts/2026-10-11/im-media-cache-regression/independent-playback-preparation-probe_test.dart`

Result: **9 PASS, exit 0**. The seven owned cases cover valid B, canceled requesting consumer, absent cache, same-length corruption, account clear, global clear, and a later I/O failure. The last case proves playback remains pending and the remaining 4096-byte reservation stays held until the second real preparation settles. The unchanged two-case reviewer probe uses its actual final file-read/Timer barrier through the real public playback entry, not a fabricated private-helper call.

## Stage 2 — QUALITY/security: PASS

No blocking finding in this bounded increment. Error handling is type-specific, request checks surround the awaited boundaries, and the successful return still passes the existing account/reference/content integrity path. The change does not alter schema, public signatures, source deduplication, scheduler admission, Matrix encryption, financial authority, account isolation or resource settlement. It does not remove real preparations from the wait set or allow canceled callers to return a surviving caller's file.

The author tree was confirmed clean at the exact SHA. The product diff is limited to this one method, with the new focused test file. The author's four source/fixture identities and five archived log identities all match normalized SHA values (9 checks). The copied original probe equals the probe frozen in d111a295 after LF normalization; its assertions/barriers were not weakened. The author RED logs show the original public 1 PASS / 1 FAIL and owned 5 PASS / 2 FAIL results, including later-error masking. The independently rerun GREEN closes these failures.

The author's 104 impacted tests and analyzer-zero evidence were read and hash-verified, not rerun or represented as independently executed. The 104 and 9 counts overlap and are not added. The documented post-impact test-only brace adjustment changes no assertion; the final focused and analyzer evidence include it. Existing negative-provider MediaIndex fallback output remains an intentional fixture.

## Disposition and exact evidence

Accept this cache sequence for parent integration in order: `44dabcc9d6428e38adfe93f572deeec0c64e8653` → `c3c66fbc4e5d779751368f0c9bce03bb5de8fd04` → `34d1263ceb53b8f9e3efe703e548aa58de82dd5e` → `766784770e04d168b0ebc64bf4647051d0db2473`. Earlier independent blockers are closed by their respective follow-ups; the previous sidecar-vs-object barrier correction remains as documented in the d111a295 report. Intermediate c3/34d snapshots should not be treated as accepted endpoints.

This is source-level SPEC/domain and QUALITY acceptance of the bounded cache work. Parent still owns integration with its newer shared SQLCipher factory, one frozen full shared gate, relevant native verification, final package identity/signing and distribution acceptance. No native performance, RSS, release, or production acceptance is claimed here. No additional scope or duplicate 104-case run is required for this incremental review.

Owned evidence under `docs/verification/artifacts/2026-10-11/im-media-cache-independent-review/`:

- `766-playback-preparation-9.log`: the fresh independent 9 PASS run, exit 0; shell wall time 5.74 seconds.
- `766-review-identities.json`: exact reviewed commits, source/log hashes, timestamp, command, result and reuse boundaries.

Next executable step: parent integrates the ordered sequence, freezes the resulting combined source, and runs its already planned shared/native/package gates. This reviewer made no product, release-helper, root-tree or production mutation.
