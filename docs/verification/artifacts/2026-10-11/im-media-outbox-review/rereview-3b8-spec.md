# Durable media follow-up SPEC/domain review

Candidate: 3b8e1bd26ff562d6bfa695b1707127bc6cb9628b, following 850710bd52d5763e8a3831e0665cb1eb5dbe44fd. Candidate tree: C:/Users/Administrator/.codex/worktrees/im-media-outbox/StarChat. HEAD and a clean status were checked before and after the independent probes. Review is read-only; artifacts live in the separate im-runtime-bounds tree.

Outcome: **CHANGES REQUIRED — one new P1 blocker.** This specification/domain phase precedes rereview-3b8-quality.md. The four original findings are resolved by the frozen follow-up, but concurrent repeated preparation of the same transaction now corrupts its active state.

## Resolved boundaries

- The original four independent probes all pass against this exact candidate: another room can persist its intent while a resolver is held; an earlier retry replaces a later timer without shortening the other task's deadline; replacement cancellation preserves a real source-copy lifetime; and replacement recovery revisits a formerly live flight after settlement. Evidence: rereview-four-green.log, 4 PASS, exit 0.
- Two additional owner-authored boundary tests were run independently: no more than two real resolver/copy preparations, and atomic competition for the last of 128 pending entries across SQLite handles. Evidence: rereview-bounds-green.log, 2 PASS, exit 0.
- Inspection confirms count plus intent insertion and byte reservation use short SQLite transactions. The shared metadata chain excludes resolver/copy/seal/network waits; preparation pins survive replacement. Retry scheduling chooses the earliest scan while each stored hard deadline remains authoritative. Orphan reconciliation now runs on each scan and excludes live flights/foreground holds.

## New blocker

**P1 — Returning an active preparing row lets a duplicate caller poison the original preparation.** In media_outbox_store.dart:428-476, the existing-transaction branch validates metadata but returns the current row immediately, including stage preparing. The first caller may still be resolving or copying its source. A second identical persistResolvedFile -> dispatch call therefore reaches verifiedSource before a digest/source is ready; dispatch records source-incomplete as failed. When the original resolver completes, its preparing-only reservation update fails, producing canceled. The original request has been lost rather than joined.

duplicate_preparation_test.dart holds the first resolver, invokes the same complete service persistence/dispatch path twice with identical txid and parameters, releases the resolver, then settles both operations and closes/deletes its fixture before asserting. The verified RED observes final stage failed rather than sent; the first result is MediaOutboxException(canceled), the duplicate result is MediaOutboxException(source-incomplete). Evidence: rereview-duplicate-verified-red.log, one assertion failure, exit 1. The earlier rereview-duplicate-red.log is exploratory and is not the final cleanup-controlled evidence.

Minimum correction: join the real preparation Future by fixed owner/root plus txid, preserving per-caller current-owner checks and true settlement. Compare immutable metadata before joining so a conflicting request cannot hijack the old intent. Preserve the two preparation slots, short metadata transactions, cancellation pins and replacement lifetime; do not restore global serialization over resolvers or copies. Add same/different-handle duplicate, mismatched metadata and cancellation/close lifetime coverage before freezing again.

## Evidence reuse and scope

The owner combined run recorded 40 PASS and 1 failed old fairness assertion, exit 1. After correcting the assertion to wait for actual B-flight settlement and to avoid an unsupported cross-room start-order assumption, the two recovery test files recorded 14 PASS, exit 0. These runs give aggregate coverage of 41 unique tests; they are not a single 41-pass exit-0 run. The 17-file analysis and final test-only analysis recorded zero issues. Unchanged Matrix/RoomPage/MMS/budget/SDK source retains the previously inspected 62 adjacent-test evidence.

Only store/recovery production files changed in this follow-up. No native device, real OS SIGKILL/power-loss, full shared candidate or complete R8 acceptance is claimed. The 700 interruption cases remain synthetic in-process boundary errors with real SQLite/file reopening. Source identity and independent log hashes are in rereview-3b8-identities.json.

Next executable step: implementer fixes the duplicate preparation lifetime, verifies focused RED/GREEN and necessary affected gates, freezes a new SHA, then requests targeted independent SPEC/domain -> QUALITY re-review. Root has accepted this blocker and authorized that next step.
