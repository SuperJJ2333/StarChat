# Durable media duplicate preparation SPEC/domain re-review

Candidate: **7c567699ad0e21b9546df3c774ccb9da5a35fe7a**, following 850710bd52d5763e8a3831e0665cb1eb5dbe44fd -> 3b8e1bd26ff562d6bfa695b1707127bc6cb9628b. Candidate tree: C:/Users/Administrator/.codex/worktrees/im-media-outbox/StarChat. Review scope is the duplicate-preparation correction; the sole production diff is 35 lines in media_outbox_store.dart. Reviewer owns only this separate artifact directory.

Outcome: **PASS for this frozen source chain and bounded review scope.** The P1 in rereview-3b8-spec.md is resolved. This SPEC/domain conclusion precedes rereview-7c-quality.md; it does not replace root's integrated/platform/release gates.

## Contract and implementation

- The short intent transaction registers a preparation Future using the fixed account/home/generation root plus txid before another metadata operation can observe the new row. No resolver, copy, native sealing or transport is moved into that transaction or its metadata chain.
- A duplicate validates room, MIME, filename, duration, prepared, asFile, width and height before joining. Each differing field retains transaction-conflict and leaves the original preparing row intact; the duplicate resolver does not execute.
- A matching caller joins the actual result, spanning source resolution, copy, seal, queued commit and the finally cleanup/permit release. If the original settles between reading the row and continuation, the code rereads the current row instead of returning a stale preparing snapshot. The shared entry retires only on actual completion/error and only if it still identifies that preparation.
- Each call's tracked operation remains in its own store's close set until the wait and caller-specific owner check settle. A revoked joiner cannot obtain a usable late result; it does not turn the valid original into failed. Existing shared copy pins, cancellation flags, byte reservations and two preparation permits retain their real lifetime.
- The two transport slots, 128-pending admission, 512 MiB retained-source accounting, 16 MiB sampled free-space reserve, txid/asFile/prepared semantics and generation-separated native/cache namespaces are unchanged. Earlier source/domain findings remain covered by their reviewed corrections and cited tests.

## Independent execution

1. The original reviewer full-service probe, unchanged from the cleanup-controlled RED on 3b8, now passes on 7c. In the same command, the four new owner tests pass: same-handle join, replacement-handle join, all eight metadata conflicts and replacement cancellation plus close. Both full-service join tests assert exactly one resolver and one event, no send before resolution, and identical successful event IDs. The cancellation test holds the resolver and proves close remains pending, then observes both callers canceled and terminal charge zero. **5 PASS, exit 0**, rereview-7c-duplicate-green.log.
2. A new independent boundary test revokes only the joining caller after it has begun waiting. It proves the caller and close remain pending until real settlement, then receives owner-unavailable while the original and durable row stay queued with the expected length. **1 PASS, exit 0**, duplicate_owner_revoke_test.dart and rereview-7c-owner-revoke-green.log.

All assertions occur after the held work is released and fixture operations settle. Tests use real SQLite/private fixture files and synthetic resolver/send callbacks. No owner source or test was edited.

## Reused evidence and limits

The prior four independent corrections and two bounded-resource tests passed on 3b8; their logs are retained unchanged. The owner also reran the complete scoped suite on 7c: duplicate-final.txt ends with **45 PASS**, and duplicate-input-hashes.json records exit 0, no failed/skipped cases and 700 synthetic boundary/reopen iterations. duplicate-analyze.txt records **18 files, zero issues**, exit 0. These final 7c results supersede the earlier 3b8 combined 40 PASS/1 FAIL followed by 14 PASS; that history remains accurately preserved in prior reports. The 62 adjacent-test evidence is reused only for unchanged Matrix/RoomPage/MMS/budget/SDK inputs.

The synthetic interruption fixture is not a real OS SIGKILL or power-loss test. No true device protection, integrated native channel/SQLite acceptance, complete project gate, RSS target or final release is asserted here. Root owns those dependent acceptance steps. Candidate and artifact identities, timing and exact test commands are in rereview-7c-identities.json.

Next executable step: root may integrate the exact 850 -> 3b8 -> 7c source chain and run its shared candidate/native/package gates. No further source change is requested by this review.
