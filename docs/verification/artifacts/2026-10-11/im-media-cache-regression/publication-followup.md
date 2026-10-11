# Late cache publication after observer cancellation

Parent-authorized follow-up to 44dabcc9d6428e38adfe93f572deeec0c64e8653. Independent reviewer backend_review provided the real path-provider barrier probe. This is a pre-existing gap (reviewer also reproduced it on 9902d350), not a newly introduced cross-account or integrity regression. The broad no-late-publication claim in the original README was not fully demonstrated until this follow-up.

## Reproduction and correction

The scheduler's independent source scope correctly outlives canceled observers to retain the real operation's budget and allow a new observer to join. Checking only that scope inside store does not establish current demand. The source's earlier hasConsumers check also precedes awaited path preparation and disk writes.

The private media_cache operation zone now carries a dynamic publication check: captured global/account generation must remain current, then the scheduler must still have a consumer (or the direct local/disk child must remain active). The scope owning the real work and its reservation is unchanged. The check is queried again rather than permanently latching the original observer's cancellation. The held-root cancel-then-rejoin test returns the verified bytes after one source call.

Publication boundaries:

- Store checks again after awaited root preparation. A last-consumer cancellation in this window leaves no object, sidecar or reference.
- Atomic object/length/reference writes check before work, after any prior same-path write, and after the new temporary file is flushed immediately before invoking rename. A cancellation before this boundary removes only that operation's unique temporary file in finally.
- Rename itself replaces an existing file; the old eager delete was removed. Thus a cancellation before rename cannot destroy the prior valid reference/object. Windows tests exercise replacement of existing refs as well as cancellation after real temporary-file flush.
- Rename submission is the publication boundary, not completion of the uncancellable filesystem Future. If demand disappears after submission, the actual rename settles while the reservation remains held. Already published objects or length sidecars are not deleted as cancellation rollback; a still-unpublished reference cannot replace its previous value. An object whose reference is abandoned remains governed by the existing orphan grace/GC policy.
- Quota accounting completes for successfully published objects. The optional reference index checks demand after file-length lookup before submitting its index write, and memory insertion checks after worker verification. No index or memory result is published from the held-root rejection. Index work submitted for a valid object/reference can finish after its caller leaves; these entries remain optimization hints, not an authorization source.
- Durable clear-epoch writes call the lower atomic writer without a consumer check, preserving cleanup behavior. The global/account generation and clearing-root checks remain independent of observer demand. No pending-media/source directory or encrypted protocol is changed.

## Evidence

| Evidence | Exact result |
| --- | --- |
| late-store-red.log | Original reviewer probe on 44dab: control PASS, last-observer cancellation FAIL; cache existed after actual settlement. Exit 1. |
| publication-red.log | New owned tests: control and held-root rejoin PASS; root cancellation, object temp-flush cancellation and reference temp-flush cancellation FAIL. Exit 1. |
| publication-green.log | Five owned probes plus the two unchanged copied reviewer probes: 7 PASS, exit 0 on final source. |
| publication-impact.log | One run of 11 impacted files: 93 PASS, exit 0; includes five owned probes, consumer scheduling/rejoin, integrity, index/GC, account clear, scheduler, bubbles, download budget, audit, playback and incoming descriptors. |
| publication-analyze.log | Changed production/test files: zero issues, exit 0. |

The 7- and 93-test runs overlap in the five owned probes and must not be summed as unique tests. A first new-test compile attempt had two test-double type errors, corrected before the behavioral RED. A first GREEN attempt reached correct product assertions but recursive enumeration hit the Windows long-path limit caused by an unnormalized `../..` fixture path; fixture normalization fixed that enumeration only. Two test-only analyzer style notices were fixed after the 93-test run; the final 7-test gate and analyzer run include those style edits. None is claimed as an earlier all-green gate.

The reviewer probe snapshot is independent-publication-probe_test.dart. It is copied unchanged; the reviewer tree was not edited. publication-input-identities.json records raw and normalized input hashes, log timestamps and the exact commands. publication-impact-run.json contains the command's UTC interval. Negative provider/index fallback messages are deliberate existing fixtures with passing assertions.

Only focused/adjacent gates were rerun. Parent retains the shared full gate, native channel/SQLite verification and package acceptance. No device RSS, real-device cancellation or release claim is made. Independent SPEC/domain then quality/security review is still required before integration. Rollback is this isolated follow-up commit reversal.
