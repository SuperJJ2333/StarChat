# R9b-2 independent Quality/Security review — PASS for source candidate

This conclusion follows `spec-review.md` for exact commit `c3dd314212c73414c5ab371b4363e077bc9104c2`. No blocking quality/security defect was found in the reviewed diff or independently exercised boundaries. Image and deployment readiness remain open; this is not cutover authorization.

Reviewed failure handling is conservative: renewal errors are classified without copying exception strings/DSNs/payloads; uncertain commit results do not become success. The renewer holds the original generation, creates no heartbeat and cannot acknowledge the event. Handler execution and transactions stay on the original thread. Success/retry/DEAD completion happens only after true renewer settlement; unresolved30s join prevents all later claims on that Worker. A stopped daemon may finish its one in-flight I/O, which is accurately disclosed rather than described as forced cancellation.

The new engine preserves caller URL routing/TLS/options and appends local timeout policy. Independent PostgreSQL testing additionally supplied120-second URL connect/statement/lock settings and verified the actual connection still reports3s connect,1s lock,5s statement/idle-transaction and5000ms TCP user timeout, while preserving `application_name`. No handler/API pool settings were changed. Real PG NOWAIT contention and statement/pool timeout tests passed. These budgets do not prove every operating-system or network stall is bounded; the poison/join behavior is the final fail-closed boundary.

The added independent lifecycle probe held the call immediately before the real Consumer renewal across the900s monotonic cap, then let that DB operation settle, and verified PROCESSING remained, ACK was withheld, the unstarted tail stayed PENDING/attempt0, the handler thread was unchanged and later calls were rejected. No second renewal started. It uses a real SQLite Consumer with explicitly injected time and a held wrapper around the DB call; it is not an actual stuck database transaction or a900-second wall-clock/device test.

Evidence actually run by this reviewer:

| Invocation | Result |
| --- | --- |
| `test_worker_active_lease.py`, `test_published_worker_entrypoint.py`, `test_worker_lease_window.py` |28 PASS/1 PG configuration SKIP,3.68s |
| `test_worker_active_lease_postgres.py`, `test_worker_lease_window.py`, isolated PG URL |13 PASS,8.12s; resolves the preceding PG skip |
| `test_independent_lease_edges.py` |2 PASS,1.41s |

Together these cover35 distinct cases, with eight deliberate repeats. The author-reported342-case impact suite, publication-receipt PG skip and old-main negative control were inspected as author evidence; they were not rerun or relabelled as independent results. Full repository/mobile verify was not run for this read-only server review. Root must still test the exact built image's normal import path and final source identities.

Fixture operations: root confirmed exclusive use of the stopped author's loopback PG cluster. Reviewer started it, created a new synthetic UTF8 database and never wrote the author's existing database. Initial attempts using `postgres` and the Windows user were rejected because those local roles do not exist; root then supplied `lease_fixture`. The startup PowerShell pipeline inherited the PG child's pipe and remained open; independent connections/tests proved the server was running. Stopping the cluster returned exit0, then that original wrapper's deferred diagnostic `psql` command failed against the deliberately stopped server (wrapper exit1). This is an explained harness issue, not a failed candidate test or a successful shutdown claim inferred from a timeout. No fixture service remains running; its data stays untracked.

Deployment limits to preserve: use a fresh exact live baseline, include all four source files and both worker API-library copies where applicable, retain the operational guard, validate actual default imports/publication handlers and image health, compare unrelated services, and provide rollback. No source-only PASS may substitute for those checks. Arbitrary process pauses/cap exhaustion can still allow another worker to take over while an old external operation finishes; queue fencing does not confer external exactly-once semantics.
