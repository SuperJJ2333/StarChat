# R2 — scoped push delivery reliability

Status: implementation candidate, not deployed; independent specification and quality/security reviews are next. Parent task owns integration, shared verification and deployment. User implementation authorization was supplied by the parent task; this worker owns only `services/getui-bridge/app/{main,rate_limit}.py`, its new test file and this evidence.

Plan: main workspace `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md`, R2; source baseline `5c83a08a09b985146bc507a1608cb2153d361e48`. Isolated workspace: `C:/Users/Administrator/.codex/worktrees/im-push-reliability/StarChat`, branch `codex/im-push-reliability`. Existing v1 sanitization/provider wire format and E2EE boundaries are unchanged.

## Behavior and decisions

- v1 ordinary-message opportunities use CID + session scope + room digest. Different rooms or sessions no longer consume one shared 1500 ms window. The gateway does not receive local mute policy or reintroduce vendor OS display; both rooms reach the device policy owner.
- Event results use CID + scope + room digest + event digest. Confirmed accepted and permanently rejected results remain for `max(300000, notify_ttl_ms)` milliseconds after completion. Partial request retries retain accepted results and replay rejected results without another provider request.
- In-flight duplicates, new events in a room cooldown and capacity exhaustion return HTTP 503 without deleting pushers. There is no in-memory tail queue claiming delivery ownership. Legacy/call per-CID/kind coalescing is retained because these envelopes have no scoped event identity.
- Each native room table and combined pending/completed event table has a hard 8192-entry cap. Native expired state is reclaimed on admission; pending entries never expire during an active worker. The legacy window table now also has a hard 8192-entry cap and reclaims expired entries when full.
- A shared nonblocking semaphore permits four provider calls per app process across all requests. The actual synchronous worker owns the reservation and slot through completion, including after cancellation of an HTTP waiter. No request waits for a provider slot; overload requests retry upstream. AnyIO still schedules request work through its existing thread pool; this is not an HTTP-server-wide request admission limit.
- Failure rollback is reservation-token checked. An old failed event cannot erase the newer event's same-room cooldown. Unexpected gathered exceptions are retried instead of accidentally acknowledged.

Ruling: explicit retry was chosen over tail coalescing because no durable queue exists in this bridge. Cost: more upstream retries during bursts or saturation. Event state is process-local and bounded by TTL, so restarts, multiple bridge processes or retries after TTL do not provide exactly-once delivery; ambiguous provider timeouts can still have been accepted externally. This patch deduplicates confirmed terminal outcomes within the stated process/TTL boundary. Device receive/display/sound and OEM-channel approval remain separate acceptance gates.

## Verification

All commands used PowerShell 7 with UTF-8 without BOM and Python UTF-8 environment variables. `PYTHONPATH=services/getui-bridge`; import preflight resolved `app.main` inside this exact worktree. Python 3.12.10, Windows 10.0.19045, httpx 0.28.1, FastAPI 0.141.1, Pydantic 2.13.4, AnyIO 4.14.2, pytest 8.4.2. No service dependency lock file exists; existing requirements and Dockerfile were unchanged and hashed in the manifest.

| Gate | Command | Actual result |
| --- | --- | --- |
| Baseline | `py -3.12 -m pytest -q -p no:cacheprovider tests/getui_bridge` | Exit 0; 38 passed, 2 warnings, 2.28 s |
| RED before implementation | `py -3.12 -m pytest -q -p no:cacheprovider tests/getui_bridge/test_delivery_reliability.py` | Exit 1; 11 failed for missing behavior, 2 existing transport cases passed, 2 warnings, 24.10 s |
| Initial GREEN | `py -3.12 -m pytest -q -p no:cacheprovider tests/getui_bridge` | Exit 0; 51 passed, 2 warnings, 3.04 s |
| Final strengthened capacity test / clock-order cleanup | Same full bridge command | Exit 0; 51 passed, 2 warnings, 2.88 s |
| Repository policy | `pwsh.exe -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1` | Exit 0; PASS |
| Deployment policy | `pwsh.exe -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1` | Exit 0; PASS |
| Diff whitespace | `git diff --check` | Exit 0 |

The two warnings are unchanged from baseline: Starlette deprecates TestClient's httpx adapter in favor of httpx2; Pydantic deprecates class-based Config. Neither warning was hidden or fixed outside scope.

New cases exercise A/B rooms 100 ms apart, local-muted A / audible B payload opportunity, scope replacement, event dedup beyond room cooldown, same-room explicit retry, mixed accepted/permanent/transient CID outcomes, HTTP 200 with transient business code, ConnectTimeout and ReadTimeout recovery and log redaction, in-flight duplicate failure semantics, old/new reservation isolation, concurrent HTTP requests, capacity reclamation, and request cancellation. Existing 38 tests remain intact.

`scripts/verify.ps1` was preflighted, not started here: this worktree has no `.env`, and `scripts/init_matrix.ps1` explicitly requires it. Parent task confirmed the shared candidate's suitable whole-repository gates will run once at integration. No production secrets were imported to fill the gap. No build, server write, deployment or device test was performed by this worker.

Local evidence: [manifest and exact input SHA256](artifacts/2026-10-11/im-push-reliability/manifest.json), [baseline](artifacts/2026-10-11/im-push-reliability/baseline.log), [RED](artifacts/2026-10-11/im-push-reliability/red.log), [initial GREEN](artifacts/2026-10-11/im-push-reliability/green.log), [final tests](artifacts/2026-10-11/im-push-reliability/final-tests.log), [repository policy](artifacts/2026-10-11/im-push-reliability/repository-policy.log), [deployment policy](artifacts/2026-10-11/im-push-reliability/deployment-policy.log). Artifacts remain in the allowed local evidence directory; this report is versioned.

## Timings and handoff

Observed checkpoints (Asia/Hong_Kong): baseline completed 2026-10-11 10:28:22+08; RED completed 10:30:28+08; initial GREEN completed 10:31:56+08; final tests and policies completed 10:33:13+08; manifest recorded 10:33:39+08. Earlier context-reading/worktree wait start and exact active-versus-tool split are unknown; no precise total is inferred. Pytest durations are reported above.

Next executable step: independently review the bounded R2 diff against plan R2, then quality/security review, followed by parent integration of the frozen commit. Rollback is bridge-code/image-only; no schema or client migration is introduced. Freeze and compare the actual production image when the parent proceeds to release.
