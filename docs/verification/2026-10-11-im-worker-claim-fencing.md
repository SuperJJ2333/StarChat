# R9b step 1: claim generation fencing, awaiting independent review

Date: 2026-10-11 (+08). Owner: backend_review. Worktree: `C:/Users/Administrator/.codex/worktrees/im-worker-claim-fencing/StarChat`. Base: `dc409a5e4652207f89b74eff2bf0b495c1795a6d`. Scope/decisions: [bounded approved-scope plan](../superpowers/plans/2026-10-11-im-worker-claim-fencing.md). This is an implementation result, not a SPEC/quality approval or deployment result.

## Behavior and limits

The Consumer now offers `renew_claim` and `mark_claim_succeeded/failed/dead`, each requiring the original positive integer `attempt_count`. The row lock predicate checks event ID, PROCESSING state, worker ID and attempt in the same transaction as the mutation. No optional token is accepted. Legacy owner-only `mark_*` methods remain for direct-call compatibility and are explicitly labelled weaker; they do not acquire the new guarantee. Worker always calls the fenced methods and rejects a Consumer missing any of its three completion methods at construction, before dispatch or maintenance. There is no legacy fallback.

Renewal uses NOWAIT row acquisition and samples the injected clock after locking. It changes only locked_at, rejects expiry at the exact reclaim boundary, and propagates DB failures without declaring success or requeueing. It does not promise a bound on connection/pool/network waiting; the future lifecycle must configure those. Completion preserves expired-but-unreclaimed behavior: a still-current generation can finish, but an old generation cannot mutate a newly claimed event even when both processes share the same worker ID.

No renewal thread or caller was enabled. Active handlers may still be reclaimed and may still perform duplicate external effects; the original strict XFAIL remains. These interfaces fence queue-state changes, not SMTP/provider/financial side effects, and do not provide exactly-once delivery. The existing injected application-clock convention is unchanged; safe multi-host renewal activation needs a separately reviewed clock and bounded lifecycle decision. No schema, financial handler, immutable receipt, handover predicate, max-attempt/retry policy or historical DEAD replay change.

## Evidence and verification

All logs below are under [task artifacts](artifacts/2026-10-11/im-worker-claim-fencing/). `input-manifest.json` binds source/tests, unchanged handler/handover dependencies, dependency lock inputs, actual import paths and tool versions. Commands use PowerShell 7, UTF-8 input/output/pipeline, `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`, `PYTHONDONTWRITEBYTECODE=1` and `PYTHONPATH=services/business-api;services/business-worker/app;.`.

| Stage | Command / result | Exit / evidence |
| --- | --- | --- |
| Baseline | `py -3.12 -m pytest tests/business_api/test_outbox.py tests/business_worker/test_worker_lease_window.py -q`: 11 PASS, 1 PG skip, 1 strict XFAIL | 0; `baseline.log` |
| RED (before product edits) | `py -3.12 -m pytest tests/business_worker/test_worker_claim_fencing.py -q --tb=short`: 42 failures. Three actual stale Worker outcomes were incorrectly accepted; remaining new-interface/validation behavior was absent | 1; `red.log` |
| Real PG RED | `py -3.12 -m pytest tests/business_worker/test_worker_claim_fencing_postgres.py -q --tb=short`: 10 failures. The three real same-worker-ID reclaims all let the old Worker complete; remaining new interfaces absent | 1; `red-postgres.log` |
| Focused GREEN | New two files plus baseline two files: 64 PASS, 1 strict XFAIL, 0 skip | 0; `green-focused.log` |
| Final affected full Worker suite and neighbors | `py -3.12 -m pytest tests/business_worker tests/business_api/test_outbox.py tests/business_api/test_outbox_handover.py tests/business_api/audit/test_outbox_publication_receipts.py -q -rs --tb=short`: 319 PASS, 1 skip, 1 strict XFAIL, 18.45s | 0; `green-final.log` |
| Final test-only lock-observation refinement | Added a bounded local `pg_stat_activity.wait_event_type` check proving the old completion is waiting for the new claim lock before release; reran `py -3.12 -m pytest tests/business_worker/test_worker_claim_fencing_postgres.py -q --tb=short`: 10 PASS, 2.42s. Product and other test inputs unchanged, so the broader gate above is reused | 0; `green-postgres-lock-observed.log` |
| Lint/format | Ruff 0.15.22 check all six changed Python files; Black 26.3.0 check two newly added test files. Earlier two test-only E731 style findings were fixed | 0; `ruff.log`, `format-check.log` |
| Repository/deployment policy | `pwsh.exe -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1`, then `Test-DeploymentPolicy.ps1` | Both PASS/0, terminal output |
| Syntax/import/diff | AST parse all Python inputs in manifest; actual Consumer/Worker imports point to this worktree; `git diff --check` for product/test/doc changes | PASS/0, manifest and terminal output |

The final tests include 52 newly added cases: 42 SQLite cases and 10 real PostgreSQL cases. Real PG competition covers success/failure/dead with same worker ID, both row-lock winner orders of claim versus completion, and renewal NOWAIT returning PostgreSQL `55P03` under a held row lock. Threads use independent sessions and bounded Event waits. Injected clock advancement simulates 301 seconds; this is not wall-clock five-minute or production load evidence. The old R9a native test also ran.

Local fixture: PostgreSQL 18.3, loopback port 55481, own empty `im_worker_lease_fencing` database under the artifact directory. New tests create/drop only random private schemas after checking the explicit local test URL. `postgres-init.log` and `postgres-stop.log` record local lifecycle; stop succeeded with exit 0. This is not a PostgreSQL 16 production-version gate. No production connection or data was used. Runtime data files are not tracked or included in the delivery.

The single final skip is `tests/business_api/audit/test_outbox_publication_receipts.py::test_real_pg_concurrent_insert_then_lost_ack_retry_and_digest_conflict`, whose existing hardcoded fixture requires another URL/port/user. That handler and receipt implementation are unchanged; no second fixture was created solely to repeat unchanged evidence. The strict XFAIL is `test_active_handler_is_not_reclaimed_while_original_handler_is_still_running`; no suppression was broadened. Its AssertionError is still the expected duplicate-handler interleaving.

The existing support compatibility test imports an untracked historical synthetic probe. Its exact file was copied into the prescribed verification path, with SHA checked before use: `335a739c829327402cd7ae383bc3aed2a06f0675a0fa66c21844c0c3167d84c8`. The test invokes synthetic SQLite `run_cases`, not its network entry point. The probe is a pre-existing verification dependency, not a new product file.

`scripts/verify.ps1` preflight found no `.env`; its render step explicitly requires it, so the full script was not launched and no production configuration was imported. Standalone static typing was not run: mypy is neither installed nor available through `uvx --offline` cache (the dependency-resolution failure's raw exit was not captured). AST/runtime protocol tests are not claimed as substitutes for static typing. Full API/mobile/infra gates and Linux/container role compatibility remain candidate-integration gates; this task's authorized isolated server change was kept out of current mobile release inputs.

## Review, integration and rollback boundary

Next: freeze this exact diff/evidence, obtain non-author domain/SPEC review, then Quality/Security review. Both changed modules must be supplied to the worker runtime together; overlaying only worker.py onto the old Consumer fails closed. An old Worker can still use the retained legacy API, so rolling/mixed versions retain the old weaker ownership semantics until all relevant workers are upgraded. Candidate guards must check actual imports, protocol and configuration. No deployment has been performed or requested by this subtask.

Rollback is a paired code/image rollback to the frozen compatible Consumer/Worker versions; no schema downgrade, receipt deletion, ledger correction or historical event replay. Ownership errors still propagate out of run_once as before; subsequent supervisor/restart and observability policy remain unchanged. A future renewal lifecycle needs its own stopped-process/DB-unknown/late-result and side-effect analysis plus the required domain and quality reviews.

## Stage ledger

- Initial pause: worktree created at base, no product/tests edited; historical [handoff](2026-10-11-im-worker-claim-fencing-handoff.md) preserved.
- Resume: required workflow/plan context checked; first recorded local timestamp 14:24:54+08. Native PG RED was inspected at 14:29:13+08 before product changes; final regression completed after 14:37:27+08. Exact active/tool/parent-wait breakdown was not captured and is unknown; no invented minute totals.
- Ruling: use repository-mandated verification paths instead of generic skill scratch directories; use the affected full Worker suite plus direct API neighbors, preserving parent's isolation from the concurrent mobile release. Cost/limit: this is not a whole-repository verification claim.
- Ruling: retain explicit legacy Consumer entry points while requiring a new fenced Worker protocol. Cost/limit: legacy callers retain weaker owner-only semantics; mixed-version deployment cannot be called fully fenced.
- Current state: implementation/test freeze ready; independent review and deployment gates remain. PostgreSQL fixture stopped; no task background process remains.
