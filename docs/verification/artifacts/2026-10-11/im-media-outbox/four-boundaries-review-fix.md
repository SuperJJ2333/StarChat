# Independent review: four boundary corrections

Base candidate: 850710bd52d5763e8a3831e0665cb1eb5dbe44fd. This follow-up changes only media_outbox_store.dart, media_outbox_recovery_service.dart and a new media_outbox_review_regression_test.dart, plus a correction to the existing cross-room test assertion (only same-room order is guaranteed). It does not represent an independent PASS; the reviewer must re-review the frozen follow-up.

## Reproduced defects and fixes

1. A pending resolver held the whole store write chain, preventing B from even writing its intent. Intent count/insertion and source-length reservation now use short SQLite transactions. At most two preparations across store instances execute resolvers/copy; queued operations already have an intent. No resolver, copy, native sealing or transport holds the short metadata chain. The existing global media memory budget remains in force around production byte resolvers.
2. A five-second timer prevented B's newly scheduled two-second retry. The service now keeps the earliest due timer. The test observes B retry by three seconds and also asserts A did not retry before its own persisted deadline. Hard server deadlines are unchanged.
3. A replacement store canceled a still-writing original owned by the previous instance. The original instance's pin was invisible, causing Windows errno 32 (and premature unlink on platforms allowing it). Active source pins now share the fixed root/txid identity across instances and remain until the real copy/resolver ends. Cancel flags are released only after terminal cleanup. No UI timeout releases a pin.
4. Initial recovery skipped a still-live old flight, then never revisited it after owner suspension/late settlement. Every scan now reconciles sending or preparing orphans only when no real flight or foreground hold exists. The replacement retains the original txid and can recover after settlement without duplicating the live attempt.

Two additional boundary assertions preserve at most two real preparation slots and atomic admission of the last of 128 pending intents across separate SQLite handles. The latter exposed SQLITE_BUSY from simultaneous FFI BEGIN IMMEDIATE; a per-fixed-root metadata chain now serializes only database mutations across those handles. Source copying and preparation never hold it. Disk reservation remains transactional and charged through actual terminal cleanup.

## Evidence

- review-regressions-behavior-red.txt: 3 actual behavior failures for resolver blocking, late retry timer, and replacement cancellation. An earlier review-regressions-red.txt contained a fixture variable-scope compile error and is not used as behavior evidence.
- replacement-flight-red.txt: replacement orphan retries expected 1, actual 0.
- cross-handle-admission-red.txt: real separate-handle SQLite busy; the last-slot regression now expects one admitted task, one queue-full and exactly 128 pending.
- review-six-regressions-green.txt: all six review/bounded-resource regressions pass.
- four-boundaries-final-green.txt ran the prior full scoped suite plus the new review regression file: 40 passed, 1 failed, exit 1. The failure was the existing fairness test assuming C starts within 500 ms of the sender ACK, before B's real durable cleanup had settled. The corrected test explicitly awaits B's true flight, then observes C while A remains pending; same-room order and the two-slot bound remain asserted.
- review-settlement-green.txt reruns both recovery test files: 14 passed, exit 0. This includes the corrected fairness assertion and all six added regressions. Product inputs are unchanged from the combined run; its other 40 passes (including 700 fault iterations and SDK/UI cases) are reused. This is aggregate coverage of the 41 unique tests, not a claim of one 41-pass/exit-0 run.
- four-boundaries-analyze-green.txt analyzes 17 files with zero issues, exit 0. The final test-only settlement-wait edit is separately analyzed in review-final-test-analyze.txt. Exit codes and hashes are in review-input-hashes.json.

The unchanged Matrix/RoomPage/MMS/budget/SDK inputs retain the 62 adjacent-test evidence from 850710bd. All seven synthetic process-boundary groups are rerun against this store/recovery implementation; they remain in-process injected interruption plus real SQLite/file reopening, not OS kills. Native platform/storage/full shared gates remain the root task's outstanding acceptance work.

## Scope separation

The optional nonlocal GalleryPhoto duration compatibility branch is not part of this follow-up. A one-line duration candidate and a real RoomPage regression were explored separately: the isolated gallery case passes, but the combined camera/gallery FakeAsync fixture leaves a Matrix poster lookup operation pending during cleanup. That combined run failed and is not counted as passing. Root directed keeping this optional branch outside the current release scope; its local WIP is preserved in gallery-duration-wip.patch for separate investigation. The reviewer confirmed the existing final group-video-size guard still applies, so no size-guard change was added.

An initial combined gate (four-boundaries-final.txt) caught an overconstrained existing assertion: independent rooms can enter transport in either order after asynchronous permission/hash checks. The test now waits for both initial slots and asserts the same set, C starts only after B actually settles, and same-room a2 remains behind A. A second gate caught the 500 ms sender-ACK assumption described above; the final test waits for the actual Future instead of a UI-style deadline. No production ordering guarantee was removed. Initial analysis also identified one missing brace; it was corrected before final validation.
