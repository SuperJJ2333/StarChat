# Shared verified-object publication demand

This parent-authorized follow-up fixes the independent review of c3c66fbc4e5d779751368f0c9bce03bb5de8fd04. The reviewer demonstrated that two separately authenticated legacy sources can converge on one content digest. The first source's Zone guard incorrectly owned their shared object Future: canceling source A also failed still-active source B. Reviewer baseline 44dab passed the same probe, so this is a c3 regression, unlike the earlier pre-existing late-store gap.

## Minimal correction

The account-local object flight now records each verified source's dynamic publication check. Atomic object/length publication uses the current union of those demands, with an independent captured global/account generation check. Canceling A cannot veto B; when all demand is gone, the pending rename is rejected. There is one real object write, no retry loop, and no cancellation-driven early retirement. Each registration is removed only when the real object Future settles.

Reference, optional index and memory publication remain in each source's original context. Thus A cannot publish its own reference just because B keeps their common object alive. Independently verified sources with the same event but distinct sourceIdentity previously encountered an earlier whole-store Future shortcut; a fourth real RED exposed that bypass. That redundant shortcut is removed so every source reaches object-demand registration and retains its own reference checks. Same-reference publication is legitimate when B remains active. Atomic same-path writes remain serialized; this does not promise to eliminate identical reference metadata writes.

The unique synchronous preparation registration in store remains unchanged and spans verification, root preparation, object/ref/index and quota completion. preparePlaybackFile still waits all registered preparations for that reference; clearAccount still observes every matching preparation and checks account epochs. Removing the redundant digest-key registration does not remove any preparation from these wait sets. Source/scheduler slots and both byte reservations stay held until actual settlement, including after both observers leave.

No scheduler, Matrix, RoomPage, native code or quota implementation changed. This branch has no dependency on df1b3 or its iOS test changes. Integrate in order: 44dabcc9d6428e38adfe93f572deeec0c64e8653, c3c66fbc4e5d779751368f0c9bce03bb5de8fd04, then this follow-up.

## Barrier correction

The independent probe is copied unchanged as independent-object-join-probe_test.dart. Its target prefix also matches the length sidecar's temporary file. Therefore that probe holds the sidecar flush, rather than the content-object flush. The earlier publication test had the same matching issue. The owned tests now explicitly exclude `.len.` and hold the actual object flush; the real regression was reproduced there too. The new evidence corrects the earlier description without changing the historic logs or weakening the independent probe. The reference barrier remains unchanged.

## Evidence

| File | Exact result |
| --- | --- |
| object-join-red.log | Unchanged independent probe on c3: 1 PASS / 1 FAIL, active B incorrectly canceled. |
| object-join-owned-red.log | Actual object-flush barrier on c3: 2 PASS / 1 FAIL; control and all-canceled cases pass. |
| store-join-red.log | Intermediate aggregate-object implementation: 3 PASS / 1 FAIL; same-event/different-source shortcut still cancels B. |
| object-join-final-green.log | Final four owned join cases, five prior publication cases and four unchanged independent cases: 13 PASS, exit 0. |
| object-join-impact.log | One run of the original 11-file 93-test group plus the new four-case file: 12 files / 97 PASS, exit 0. |
| object-join-analyze.log | Final three modified production/test files: zero issues, exit 0. |

The 13 and 97 counts overlap and are not added. The 97-test run includes the prior five store-publication tests and new four object-join tests, plus consumer/scheduler, descriptor/account integrity, download budget, cache clear, playback, index/GC, audit and bubble lifecycle groups. A later test-only deletion of diagnostic print output removed the analyzer notice; the final 13-test run and analyzer both include that change. Production inputs are unchanged between these final gates. object-join-impact-timing.json records the exact run interval. object-join-input-identities.json binds final sources, fixtures, lockfile and retained logs with raw and LF-normalized hashes; raw transient logs remain ignored.

The new tests assert independently verified source calls, two live consumers, B joining while A's real object temporary flush is held, retained 8192-byte reservations until settlement, one object write, independent reference behavior and no object after both leave. The same-reference variant detects the old pre-root shortcut as well as the corrected real-root join. All fixtures use synthetic account/descriptors/bytes and bounded five-second waits.

This is an implementer gate, not independent approval or final delivery. backend_review must perform SPEC/domain then quality/security review. The parent owns the shared full gate, including root's newer shared SQLCipher factory and native channel/SQLite assembly, final package and distribution acceptance. These isolated tests do not include that newer factory integration and do not establish RSS or device behavior. Reverse only this follow-up to roll back to c3; c3 itself still contains the demonstrated regression.
