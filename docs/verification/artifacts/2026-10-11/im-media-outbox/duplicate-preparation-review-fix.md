# Duplicate preparation: incremental review fix

Parent candidate: 3b8e1bd26ff562d6bfa695b1707127bc6cb9628b (after 850710bd). Product change is confined to media_outbox_store.dart; the new test is media_outbox_duplicate_preparation_test.dart.

## Defect and minimum fix

The independent service probe reproduced a live resolver A plus duplicate B with the same transaction. B received a preparing row, dispatched it and wrote source-incomplete/failed; A then failed its preparing reservation CAS as canceled. No event was sent. duplicate-preparation-red.txt records this actual behavior with complete cleanup.

The short admission transaction now registers the actual preparation Future by fixed root (which contains account/home/generation scope) plus txid. Existing immutable routing/presentation fields are compared before a caller can join: room, MIME, filename, duration, prepared, asFile, width and height. Different parameters fail transaction-conflict and cannot replace or poison the original. A matching duplicate waits for the same real preparation; its resolver is not invoked. If preparation settled between the row read and continuation, the caller refreshes the row rather than returning a stale preparing snapshot.

The shared Future spans resolver, copy, seal, queued commit and cleanup. It is removed only when the actual operation settles. Each joining store tracks that Future for close, and rechecks its current-owner callback after waiting. Existing cancellation, copy pinning, two preparation permits, two room transport slots and the 128-intent transaction remain unchanged. No global resolver/copy serial chain was restored.

## Verification

The new four tests cover full service persistence + dispatch on the same handle and across replacement handles (one resolver and one event; no send before resolution), all eight immutable conflicts without disturbing the live row, and replacement cancellation/close while the shared resolver is pending. The latter asserts close remains pending until resolution, both callers receive canceled, and the final canceled source charge is zero. All media is synthetic and there are no network calls.

The initial combined review/recovery run passed 18 tests. Final commands add the new file to the previous complete scoped suite and analyze it alongside the prior 17 files. The actual final exit codes, counts, source/dependency/evidence hashes and timestamps are recorded in duplicate-input-hashes.json; logs are duplicate-final.txt and duplicate-analyze.txt. No result from the optional excluded gallery-duration WIP is included.

Unchanged Matrix/RoomPage/MMS/budget/SDK code retains the 62-adjacent-test evidence. Native Android/iOS channel/protection/FFI acceptance and the root integrated full project gates remain outside this Windows-scoped validation. This report is an implementer handoff, not an independent review PASS.
