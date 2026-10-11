# R9b-2 independent SPEC/domain review — PASS

Reviewer: review_r1_r2. Date: 2026-10-11. Frozen candidate `c3dd314212c73414c5ab371b4363e077bc9104c2`; base `5988deb48185f4f2fb0743615f17ccea597671ce`. Author tree `im-worker-active-lease/StarChat` was inspected read-only. This review preceded the Quality/Security conclusion. No author/root source, production state, financial schema/handler or deployment was changed.

Specification: approved R9 and `docs/superpowers/plans/2026-10-11-im-worker-active-lease.md`. Reviewed product diff is four files: worker lifecycle, new dedicated renewal engine, main assembly and Consumer lease clock. Test corrections retain original assertions; the former instantaneous301s XFAIL is now an explicit pause/reclaim control rather than a false assertion of uninterrupted renewal.

| Contract | Independent assessment |
| --- | --- |
| Handler remains on caller's original thread | `Worker.run_once` invokes it synchronously; only renewal runs in one daemon lifecycle thread. Actual blocked-handler test verifies caller thread identity. |
| Event/worker/attempt generation retained | Frozen `OutboxMessage`, original token captured, Consumer predicates require PROCESSING+worker+attempt; renew uses NOWAIT and rejects expired lease. No owner-only completion fallback was added. |
| Renew before5min expiry, bounded15min policy | Default60s cadence and900s monotonic cap. One already-started renewal may settle past the cap; an independent held-call wrapper around the real Consumer confirms no ACK or later claim then occurs. This is not a guarantee for arbitrarily long handlers. |
| Stop, true settlement and completion ordering | SIGTERM stop event prevents further loop claims; current handler retains bounded renewal. `finish` signals stop and joins before success/FAILED/DEAD. Unsettled join, lost lease, unknown DB outcome and cap poison the Worker and skip completion. |
| Fresh bounded production DB access | Actual main creates a separate engine and consumer. Sessions are short; PG budgets are connect3s, pool1s, lock1s, statement5s and idle-transaction5s. API/handler engine policy is unchanged. |
| Clock authority and pause recovery | Default PG claim/renew use database `clock_timestamp`; deterministic injected clocks remain supported. Independent PG execution verifies clock skew behavior. The301s pause/competitor takeover control still rejects the old generation's completion. |
| Domain boundary | Only queue ownership/timestamps change. No ledger, financial transition, E2EE, recovery key, historical DEAD replay/delete, schema or audit policy mutation. External side effects remain at-least-once and require existing handler idempotency. |

Independent execution, not author-report substitution: first28 PASS/1 PG SKIP across lifecycle/default-entry/lease-window tests; then13 PASS with an isolated real PostgreSQL database, covering the skipped case and four PG lifecycle contracts; then2 new independent edge tests PASS. There are35 distinct cases across these calls (the second call intentionally reruns eight earlier lease-window cases). The genuine PostgreSQL instance uses loopback55483, version18.3, synthetic role `lease_fixture`; the review wrote only `im_worker_lease_independent_utf8`, with per-test schemas where the source fixture supplies them. It was stopped after review. See logs and `review-identities.json`.

No specification/domain blocker was found in this frozen source candidate. Actual candidate-image default import/assembly and live deployment are separate open gates. Windows pytest/main execution is not a claim that the final production image was validated.
