# R9b-2 active-handler renewal candidate

Author: backend_review. Base `5988deb48185f4f2fb0743615f17ccea597671ce`; independent branch `codex/im-worker-active-lease`. Implementation and author verification only; independent SPEC/domain then QUALITY/security remain required. No server access, deployment, historical DEAD replay/delete, schema or financial-handler changes occurred.

## Exact production scope

| File | Change |
| --- | --- |
| `services/business-worker/app/worker.py` | One bounded renewer per active claim. Handler remains on calling thread; original mandatory event/worker/attempt token; stop and join before success/retry/DEAD. Lost/unknown/cap/unsettled state prevents completion and poisons this Worker against new claims. `run_forever` passes its stop signal into the claim loop. |
| `services/business-worker/app/lease_renewal.py` | New dedicated DB engine factory: one connection, zero overflow, 1s pool wait, 3s libpq connect timeout, 5s statement/idle-transaction timeouts, 1s lock timeout, TCP keepalive/user timeout. Preserves URL TLS/routing and existing PG options. No changes to API/handler pool. |
| `services/business-worker/app/main.py` | Exactly five added lines: factory import, dedicated engine creation, ExitStack disposal callback, separate Consumer/Session factory, Worker renewal_consumer argument. Existing handlers and all other main behavior unchanged. |
| `services/business-api/app/core/outbox.py` | Default PostgreSQL claim/renew lease timestamps use DB clock_timestamp. Explicit injected fixture clocks and SQLite remain supported. No schema or completion-token changes. |

This is **not** a deployable whole-file overlay over an unverified live baseline. Root must compare live `main.py` and all four source inputs against the approved baseline, preserve any live-only logic, build/test the exact candidate and recheck deployment authorization after the mobile release. The worker image includes both API library and worker source; do not publish only worker.py or omit the new module. No API service redeploy is implied by this report.

## Lifecycle policy and limitations

- Defaults: 60s cadence, 900s monotonic cap, 30s join budget after handler return. The cap is an operational policy, not an arbitrary-duration guarantee. No next renewal starts after it; one already-running I/O may settle later.
- A fresh short Session is created for every renewal; handlers keep their original thread, transaction ownership and existing idempotency. Renewable ownership is queue ownership only. This does not fence external effects or create exactly-once processing.
- SIGTERM stops additional claims. An already-active handler keeps the same bounded renewal policy. There is no synthetic heartbeat from the renewer; a wedged handler remains visibly unhealthy.
- Renewal ownership rejection, database uncertainty (including commit result unknown), cap, and unresolved join leave the row PROCESSING. No stale ACK/FAILED/DEAD or lock clearing is attempted; normal lease expiry permits recovery. Error reporting uses stable categories, never DB exception text/DSNs/payloads.
- The original thread cannot safely be killed. A process pause, process death, lease loss, cap exhaustion or unknown I/O still permits a later retry while old external side effects might arrive. Existing business idempotency remains mandatory.
- DB/driver budgets bound the tested connect/statement/pool/lock phases, not every possible OS/network stall or an entire arbitrary transaction. If a call remains unresolved after 30s join, the Worker throws and is unusable; its stopped daemon may finish that one call but cannot start another. In the normal main entrypoint the unhandled error exits the process. Do not claim a stuck syscall was forcibly cancelled.
- Direct Worker injection remains compatible but requires the generation-fenced renew method. The shipped main wiring uses the dedicated bounded engine; custom embedding is responsible for equivalent I/O bounds.

## Evidence and true exit codes

All pytest calls use Python 3.12, `-q -p no:cacheprovider`, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`, and `PYTHONPATH=services/business-api;services/business-worker/app;<tree>`. Tool/lock/input SHA identities and commands are in `input-identities.json`. Committed log text normalizes line endings and strips trailing whitespace only; original raw output is retained locally in untracked `.raw` siblings.

| Evidence | Result | Meaning |
| --- | --- | --- |
| `baseline.log` | exit 1: 307 PASS, 12 SKIP, 1 strict XFAIL, 1 FAIL | Unchanged base. Failure is missing untracked historical `2026-09-30/support-worker-compatibility/worker_probe.py` in fresh worktree. Completed before interruption; reused without rerun. |
| `active-red.log` | exit 1: 1 FAIL | Before product edits: genuinely blocked handler, real file SQLite Consumer, six gradual 60s clock advances; competitor dispatches attempt 2; original ACK fenced. |
| `active-green.log` | exit 0: 1 PASS | Same reproducer after lifecycle implementation. |
| `lifecycle-green.log` | exit 0: 13 PASS | Success/retry/DEAD settle order, STOP, cap, reset generation, lost/expired/unknown/commit-unknown, bounded unresolved join. |
| `pg-contract-red.log` | exit 1: 3 FAIL | Real PG default clock wrongly follows skewed host (behavior RED); two additional failures identify not-yet-created dedicated factory. An earlier SQL_ASCII fixture setup error was corrected to a separate UTF8 database and is not claimed as behavioral RED. |
| `pg-contract-green.log` | exit 0: 16 PASS | Earlier 13 lifecycle + 3 PG tests: real DB clock, 5s pg_sleep cancellation/1s pool wait, separate handler/renewal connections beyond 300s. |
| `budget-red.log` | exit 1: 4 FAIL, 1 PASS | Renew thread BaseException incorrectly allowed ACK; nonfinite max/join accepted. Fixed by fail-closed termination and finite budget validation. Warning is part of this intentional RED, absent in final GREEN. |
| `default-entry-negative-control.log` | exit 1: 1 FAIL | New normal-import/main-call probe against base main.py (extracted into own artifact directory) rejects absent independent renewal wiring. This is an explicit negative control, not claimed as preimplementation TDD. |
| `default-entry-green.log` | exit 0: 2 PASS | Actual main/default imports execute real internal receipt and real independent renewal SQL, with external/maintenance dependencies isolated. An initial fixture missing a required reason_code was corrected; not counted as product RED. |
| `impact-first.log` | exit 1: 339 PASS, 1 SKIP, 2 FAIL | Existing main test doubles lacked database_url/renewal factory. Doubles were completed; original shutdown assertions retained and renewed engine disposal asserted. |
| `impact-green.log` | exit 0: 342 PASS, 1 SKIP, no XFAIL | All worker tests plus Outbox, handover, publication receipt tests, excluding only the baseline-proven missing historical fixture. Includes 18 lifecycle tests, 4 new real PG tests and existing PG fencing races. New PG NOWAIT lock rejection proves no blocked completion or stale ACK. |

Remaining SKIP: publication-receipt suite's separate `OUTBOX_PUBLICATION_TEST_DATABASE_URL` fixture was not configured; its unchanged code is not represented as PG-verified here. Renewal/fencing PG tests use an explicit local-only `IM_WORKER_LEASE_TEST_DATABASE_URL` and private per-test schemas. PostgreSQL 18.3, own port 55483, synthetic `im_worker_lease_active_utf8`; production data or credentials were never used.

The old strict XFAIL's instantaneous 301-second jump is now an explicit **whole-process-pause** control. It still asserts the full duplicate trace `a-enter, b-enter, a-exit` and rejection of old ACK. The working-renewer case has its own real blocked-thread/gradual-clock test. No claim is made that pausing the whole process beyond its lease prevents duplicate external execution.

`git diff --check`, four-source in-memory AST parse and repository policy passed. `scripts/verify.ps1` was preflighted: it also renders infrastructure, runs the entire API/mobile/UI suite, migrations and OpenAPI. This bounded server-only iteration uses the complete worker/Outbox/handover/publication impact group above; unrelated mobile/build gates are not rerun and full verify is **not** claimed to pass. No lint/type configuration is introduced. No production image/platform verification is claimed by these Windows/native-PG tests.

## Reproduction / handoff

The local fixture is stopped after verification; its data is not committed. A reviewer may create a new synthetic UTF8 PG database whose name starts `im_worker_lease_`, or restart this own fixture using `pg_ctl -D <artifact-dir>/pgdata -l <artifact-dir>/pg-server.log -o "-h 127.0.0.1 -p 55483" -w start`. Never point these tests at a production database. All PG tests reject other hosts/database names before DDL.

Final impact command:

```powershell
py -3.12 -m pytest -q -p no:cacheprovider tests/business_worker tests/business_api/test_outbox.py tests/business_api/test_outbox_handover.py tests/business_api/audit/test_outbox_publication_receipts.py --ignore=tests/business_worker/test_support_recovery_compatibility.py
```

Source/image rollback requires no data migration; already-renewed locked_at values merely delay retry until normal expiry. Final deployment requires fresh live source/config/image/schema comparison, compatible fenced Consumer + main assembly, isolated image tests, reviewed cutover/rollback and root authorization. Historical dead letters and financial operations remain outside this task.
