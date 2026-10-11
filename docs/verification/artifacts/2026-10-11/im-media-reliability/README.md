# R3 business media I/O boundary

Authorization: parent task assigns the approved 2026-10-11 IM reliability plan R3; implement and commit only, no deployment. Base commit `5c83a08a09b985146bc507a1608cb2153d361e48`. Worktree `C:/Users/Administrator/.codex/worktrees/im-media-reliability/StarChat`, branch `codex/im-media-reliability`. Owned production files: `services/business-api/app/api/media_platform.py`, `services/business-api/app/api/profile.py`; owned test: `tests/business_api/media_platform/test_media_event_loop.py`. No schema, SDK, configuration or API contract changes.

## Change and scope

Nine synchronous blob paths ran directly on the ASGI event loop. Six handlers without awaits now use FastAPI's synchronous route dispatch: signed media, authenticated variant, avatar read, avatar complete, avatar cancel, avatar delete. Three mixed request-body paths use Starlette `run_in_threadpool` for the complete service operation: direct ingest, Moment attachment, avatar content upload. Session creation, SQL execution, commits and close remain inside their existing service methods and execute in one worker thread. There is no shared Session and no executor or per-request thread creation.

Signature/private/audience rules, live authorization, revocation, checksums, declared/object byte bounds, error mapping, audit/idempotency behavior and complete-before-response semantics are unchanged. Existing S3 backend keeps closing response bodies in `finally`; it was not modified. Matrix encrypted media is outside this patch.

## Evidence

Commands run with PowerShell 7 UTF-8 console/pipeline; `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`, `PYTHONPATH=<this worktree>/services/business-api`; Python is primary checkout `.venv/Scripts/python.exe`. `environment.txt` records OS and dependency versions. `input-hashes.json` binds both production files, the test and requirements lock.

| Gate | Command after `python` | Exit / result | Evidence |
| --- | --- | --- | --- |
| RED | `-m pytest tests/business_api/media_platform/test_media_event_loop.py -q --tb=short` before implementation | 1; all 9 cases failed on shared-loop blocking assertion, 46.24s | `red.txt` |
| Initial GREEN | Same command, nine cases | 0; 9 passed, 33.57s | `green-initial.txt` |
| Boundary GREEN | Same command, expanded safety coverage | 0; 15 passed, 53.69s | `green-boundaries.txt` |
| Adjacent regressions | `-m pytest tests/business_api/media_platform tests/business_api/media_platform_readiness tests/business_api/media_storage tests/business_api/identity/test_profile_api.py tests/business_api/identity/test_avatar_version_url.py -q --tb=short --ignore=tests/business_api/media_platform/test_media_event_loop.py` | 1; 220 passed, 1 environment import failure, 347.97s | `regression.txt` |
| Worker-path repair | `-m pytest tests/business_api/media_storage/test_s3_avatar_cleanup.py::test_cleanup_worker_retry_rejects_current_pointer -q --tb=short`, adding this worktree's `services/business-worker/app` and root to PYTHONPATH | 0; 1 passed, 2.24s | `regression-worker-path.txt` |
| Synthetic two-process calibration | `docs/verification/artifacts/2026-10-11/im-media-reliability/two_worker_probe.py` | 0; 24 responses verified; calibrated loop P99 below 50ms in both processes | `two-worker-probe.json`, `two-worker-probe.txt` |
| AST / patch | Parse both production files and test; `git diff --check` | 0 | `environment.txt`; tool output |

The initial test authoring attempt had a fixture error (missing required `IngestRequest.digest_kind`). It was corrected before the real RED run and before any production edit. No implementation success was inferred from this setup failure.

The adjacent suite's sole failure was `test_cleanup_worker_retry_rejects_current_pointer`: `ModuleNotFoundError: tasks`, because the first command omitted the business-worker import path. Adding that path fixed the environment; the exact failing test passed with no source change. The 220 successful tests use unchanged inputs and are reused under the mobile workflow's change-impact rule. This is 221 adjacent tests covered across two commands, not a claimed single all-green invocation.

The 15 boundary cases cover all nine route paths, worker/Session thread ownership and close, S3 body ownership and close, no response before verified bytes, a two-token framework pool limit with a third read queued, AnyIO cancel-scope cleanup without abandoning the worker, timeout, bad full-object checksum, injected ENOSPC and recovery, and revocation while an avatar read waits for a worker. Existing authorization/storage tests supply expired/tampered signatures, cross-user access, grants, byte bounds and concurrency-race coverage.

## Calibration and limitations

Two isolated processes each instantiated the real app and issued 12 reads, two media requests concurrently per process, using 64 KiB synthetic opaque objects and a 250ms injected synchronous body wait. The default per-process framework limit was 40 tokens; maximum observed occupancy was 3 including the lightweight route's global dependency. Each process collected 149 independent 10ms timer samples. Loop P99 was 2.18 / 3.19ms; light-request P99 4.76 / 4.97ms; peak working set 145,682,432 / 145,739,776 bytes. On Windows, the probe rejects early timer wakes until the perf-counter deadline, so samples cannot be inflated by the coarse event-loop clock.

An earlier overload experiment forced the shared framework pool down to two slots and submitted twelve concurrent media requests per process. One process exceeded the provisional loop budget (91.90ms; only four samples because the original monitor coupled timer sampling to light requests), and light requests waited about 1550ms. Exit 1 is retained in `two-worker-saturated-pool.txt`. The health/live handler itself is async, but the real app has global synchronous dependencies using that same pool. This demonstrates a remaining shared-pool saturation boundary; it is not evidence that production P95/P99 is met. The corrected default-pool calibration is a different, explicitly stated load, not a replacement for this failed experiment.

This is process-isolated ASGI testing, not an actual two-worker Uvicorn listener, real S3 latency, network disconnect or peak production load. AnyIO scoped cancellation is covered; arbitrary force termination is not. Full objects still buffer in memory, request-body admission and aggregate byte limits are unchanged, and the default 40-thread shared pool is not a dedicated media memory budget. No streaming or throughput claim is made.

`scripts/verify.ps1` preflight found this clean worktree has no `.env`; its render-only stage needs that input. No production secrets were imported and the full script is not reported as passed. The parent coordinates one integrated applicable full gate after combining independent patches; unchanged unrelated gates should not be duplicated here. Independent specification review followed by quality/security review and release guard evaluation remain parent responsibilities before deployment.

## Timing and handoff

The first explicit local baseline timestamp is 2026-10-11 10:28:32 +08. Earlier discovery/worktree creation start is unknown. Real RED setup logs start 10:30:47 +08; the command reports 46.24s total. GREEN command durations above are tool/test measured; absolute boundaries not captured are unknown. The final calibrated probe ran at 10:37:07 +08 and completed within the 8.42s tool invocation. Parallel regression intervals overlap these steps and are not added to produce a false total.

Adjacent verification completed at the 2026-10-11 10:40 +08 stage (exact command end not captured). Next executable step: parent SPEC → quality/security review and integrated applicable gates for the frozen patch. No production state changed; rollback for a later authorized release is the parent's frozen compatible API artifact, with no database downgrade or object deletion.
