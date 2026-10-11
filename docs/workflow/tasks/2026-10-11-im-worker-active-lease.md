# R9b-2 active-handler renewal task

## Recovery entry

- Authorization/plan: user explicitly continued the approved R9 task; `docs/superpowers/plans/2026-10-11-im-worker-active-lease.md`. No deployment.
- Owner: backend_review; `C:/Users/Administrator/.codex/worktrees/im-worker-active-lease/StarChat`, branch `codex/im-worker-active-lease`, base `5988deb48185f4f2fb0743615f17ccea597671ce`.
- Owned files: worker lifecycle and minimal main/renewal DB factory; Consumer lease clock/public renewal interface if necessary; corresponding tests; this task, plan, own verification artifacts.
- State: implementation and author validation complete; pending independent SPEC/domain then QUALITY/security. Last update 2026-10-11 17:20 +08:00.
- Next executable action: review frozen candidate and exact four-source hashes in own artifact README/input-identities.json; do not deploy.

## Acceptance ledger

| ID | Expected behavior | Evidence/status |
| --- | --- | --- |
| AL1 | Active handler beyond five minutes retains claim while renewal operates | Real blocked-handler RED 1 FAIL → GREEN; real PG independent connection PASS |
| AL2 | Stop/ownership loss/unknown result/cap fail closed; no late ACK | 18 lifecycle tests in final impact PASS; finite/aborted-thread RED fixed |
| AL3 | Default entrypoint uses separate bounded DB I/O, shared DB lease clock | Actual main 2 PASS; old-main negative control FAIL; real PG clock and timeout PASS |
| AL4 | PG contention, original idempotency and handover behavior preserved | Final 342 PASS/1 separate receipt PG SKIP; existing historical missing fixture excluded explicitly |
| AL5 | Independent SPEC then QUALITY, no deployment | pending |

## Timings and input identity

- Baseline started 2026-10-11 16:41:23.9349548 +08; pytest reports 33.51 seconds. It completed before interruption; recovered on resume, not rerun.
- Baseline: 307 passed, 12 skipped, 1 known strict XFAIL; 1 failed because `docs/verification/artifacts/2026-09-30/support-worker-compatibility/worker_probe.py` is absent in fresh worktree. This is a missing historical fixture, not candidate behavior. Log `docs/verification/artifacts/2026-10-11/im-worker-active-lease/baseline.log`, exit 1.
- Source clean at resume; no running baseline process. Investigation/interruption durations are not known precisely.
- Resume inspection at 17:04 +08. Current artifact directory is the sole temporary-file destination.
- Implementation/verification resumed 17:04–17:20 +08, including test-fixture correction and waits. Final impact reports 25.24s. Earlier logs preserve intermediate failures. Detailed evidence in `docs/verification/artifacts/2026-10-11/im-worker-active-lease/README.md`.

## Handoff/rollback

- This candidate has not been deployed. Root's mobile baseline remains unchanged.
- Financial handlers/schema/history DEAD, E2EE, audit and existing fenced completion interfaces remain out of scope for modification.
- An unstoppable handler or paused process may still execute after lease expiry; no external exactly-once claim. No healthy heartbeat is synthesized by the renewer.
- Local synthetic PostgreSQL on port 55483 is stopped after verification; data is intentionally untracked. No running tests remain at handoff.
