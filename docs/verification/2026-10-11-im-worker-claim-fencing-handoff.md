# R9b first-step handoff — initial pause record

Resumed after the parent released a slot. The initial pause below is historical; current implementation/evidence and remaining gates are in [the verification record](2026-10-11-im-worker-claim-fencing.md).

- Date: 2026-10-11 (+08).
- Worktree: `C:/Users/Administrator/.codex/worktrees/im-worker-claim-fencing/StarChat`.
- Verified base: `dc409a5e4652207f89b74eff2bf0b495c1795a6d`.
- Stage: isolated worktree created; implementation paused at parent request to release a review slot for the current client candidate. No product code or test changes, no RED/GREEN run, no PostgreSQL fixture started, no production access or deployment in this stage.
- Pre-handoff verification: `git rev-parse HEAD` and `git status --short` exited 0; tree was clean before this handoff document.

## Authorized bounded scope

Implement Consumer public claim interfaces and Worker wiring, with required `(event_id, worker_id, attempt_count)` checks for renew and success/fail/dead in the transaction that mutates the event. Do not implement a renewal thread, change schema or financial handlers, replay historical DEAD events, or claim exactly-once delivery. This step cannot close the existing active-handler-over-five-minutes strict XFAIL.

The intended compatibility design is additive explicitly fenced methods with a required attempt token, retaining existing legacy Consumer entry points for direct callers. Worker must use only the fenced entry points with the attempt from its original claimed message; it must not look up a newer token or silently fall back to a legacy call. Final API names are not yet selected or implemented.

Renew must reject a stale generation and an expired claim; evaluate its time after obtaining the row lock. Completion may preserve the existing expired-but-not-reclaimed behavior for the same generation. Once a competitor has reclaimed the event and incremented the attempt, every old-generation completion outcome must reject, including when both workers use the same worker ID. This fences queue ownership; it cannot undo an external side effect already performed by a stale handler.

## Next executable step

1. Resume this same worktree. Read the current approved R9 plan and required workflow context; check the base and any root changes before deciding whether to rebase.
2. Write a short concrete implementation plan and test-only RED cases for required generation validation, same-worker-ID reclaim, renew expiry, success/failure/dead stale ownership, Worker propagation, and both orders of a real PostgreSQL claim-versus-completion race. Preserve current active-handler XFAIL.
3. Run RED and record commands, exit codes and intended failures before product edits. Implement the smallest public interface/Worker change; update only necessary test doubles.
4. Run focused GREEN and bounded native PostgreSQL competition in a new empty local fixture cluster under this worktree's verification artifacts. No production database access. Reuse unchanged gates appropriately and record limitations rather than claiming an unrun gate.
5. Freeze source/test/evidence identities and obtain non-author domain/SPEC review followed by Quality/Security review. No deployment is authorized for this subtask.

Prior analysis remains in the separate review worktree at `C:/Users/Administrator/.codex/worktrees/im-worker-lease-review/StarChat/docs/verification/2026-10-11-im-worker-active-lease-design-notes.md` (recorded SHA-256 `9f7941397ea4fd80d1400605ce3a733b97e2f511e52799fce16cf254ce22ccea`). It is design evidence, not a completed implementation.
