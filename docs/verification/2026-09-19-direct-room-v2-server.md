# Direct-room V2 server evidence

Task: [logical conversation reliability](../superpowers/plans/2026-09-19-logical-conversation-reliability.md). Server subtask only; no production operations or commit performed by this subagent.

Baseline `8051edb585890ddfb6d8cafe3785828dda6ff342`, branch `codex/conversation-reliability-20260919`, isolated shared worktree `.worktrees/conversation-reliability`. Windows, PowerShell 7 UTF-8, Python 3.12.10 from root `.venv/Scripts/python.exe`, `PYTHONPATH=services/business-api`, `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`. System `python` lacked argon2: initial collection failed before tests; corrected to existing virtualenv without installing packages or changing locks.

## Tests and timing

Exact subtask wall-clock start was not captured; do not infer it. Completion checkpoint: 2026-09-19 18:55 +08. Test process elapsed times below are measured command output, not additive task elapsed time.

1. Red: `python -m pytest tests/business_api/friendship/test_direct_room_recovery.py -q`, exit 1, five failures for missing `claim_direct_conversation_v2`, 5.26 seconds. Covers lost claim, lost create/publish, legacy upgrade, invalid evidence and concurrent claims.
2. First green: new recovery plus legacy coordination, exit 0, 14 passed in 7.72 seconds.
3. `python scripts/export_openapi.py`, exit 0. `python -m pytest tests/business_api/friendship tests/business_api/test_openapi_contract.py -q`, exit 0, 71 passed in 126.84 seconds. One installed Starlette/httpx deprecation warning, unrelated to the changes; no runtime bypass added.
4. `python -m pytest tests/business_api/test_migrations.py -q`, exit 0, 12 passed in 14.89 seconds. Single `0070_direct_room_history (wallet_access)` head, expand-only SQL verified. An earlier direct Alembic call from repository root failed because script_location is relative to business-api; tests execute with the correct cwd.
5. Final expanded recovery/API success tests plus migration suite: `python -m pytest tests/business_api/friendship/test_direct_room_recovery.py tests/business_api/test_migrations.py -q`, exit 0, 27 passed in 43.64 seconds. Tests include authenticated route-to-gateway wiring, 401/422, both-device association read, concurrent publication/audit exactly once, encryption/member/marker/alias mismatch, Matrix failure/replay and historical canonical immutability.
6. `git diff --check -- services/business-api tests/business_api packages/api-contracts`, exit 0. Git emits the configured LF/CRLF advisory for generated OpenAPI; no whitespace error.

Latest input SHA256:

| Input | SHA256 |
| --- | --- |
| `app/modules/friendship/direct_room_recovery.py` | `73ED0CF8C12ED476711495414BACEA89D2C4EFD1D76F64821FD43AFFA35346FC` |
| `app/modules/friendship/service.py` | `0B2AF92DE112D261651C417C4E6AC6F4F90B917978BBDA8E7B2FCCEDACAF713C` |
| `services/business-api/requirements.lock` | `029A0A13294BC678FE9E8F93B85AD74C0C78AA775F0BAE4F1802503E29D9350E` |
| `tests/business_api/friendship/test_direct_room_recovery.py` | `707B41B00B571884AA56FE1583DB25CC63E8EAC998466A0A85CD3D81D3A6ABBC` |

## Review handoff

Specification self-check: repeated claims preserve alias identity; legacy grants never reissue; first publication requires Matrix evidence; canonical never replaced; history shared across accounts/devices via verified metadata; audit+Outbox use existing transaction boundary. API additions preserve legacy schemas. Physical duplicate rooms explicitly allowed by approved ADR; source events and keys are not moved or deleted.

Quality/security self-check after specification: pair lock serializes all source association writes; exact expected Matrix IDs come from public identity boundary; configured homeserver determines alias resolution URL; unknown metadata fails closed; new API operations require actor auth and mutation rate limits; new table has pair/room uniqueness; no sensitive logging or financial changes. Independent root review is still required.

Remaining gates owned by root: `verify.ps1` environment preflight/full appropriate gates (`.env` absent here); PostgreSQL concurrency in isolated restored production schema; actual Synapse fixed-alias collision/response-loss behavior; current production source/schema drift, deployment, canonical reconciliation and endpoint/auth/source-hash checks; client integration and device acceptance. Unit tests do not prove those gates. Exact overlay and repair steps: [runbook](../runbooks/direct-room-v2-recovery.md). Domain decision: [ADR](../adr/2026-09-19-recoverable-direct-room-alias.md).

## Specification review correction — 19:01 +08

Root review identified that legacy registration/publication could still create an unchecked canonical, and late valid candidates were associated only for V2 reservations. Four added regressions failed on these exact gaps (exit 1, 4.83s). All first legacy canonical writes now verify exact-pair/encryption metadata and record the source; late differing candidates for any existing canonical are verified/associated and return canonical. Same-canonical replay stays available without new Matrix evidence. Registration idempotency still rejects changed payloads, while historical candidates from older idempotent registrations are not silently skipped.

Legacy fixtures now provide explicit valid Matrix state and Matrix profile IDs. New tests also assert forged late candidates cannot associate or replace canonical. Final `python -m pytest tests/business_api/friendship/test_direct_room_recovery.py tests/business_api/friendship/test_direct_room_coordination.py tests/business_api/friendship/test_friend_refactor.py -q`: exit 0, **37 passed in 30.89s**; diff whitespace check exit 0. No API schema or migration change in this correction.

Updated SHA256: `app/modules/friendship/service.py` = `1DE74A11CA6BD141413D03B6D31EEF4DA4AF794C56DDD3A9ABF53F8DFCDC25CD`; recovery test = `C5B86AA09E3E549695E323F7330D22D1D5E635DE4D945113EC42F27C5F1A71CA`. Earlier hashes/results remain historical evidence, not the final corrected source identity. ADR and runbook updated. Independent security review/deployment remain with root.

## Production completion — 19:37 +08

After root-authorized final gates/reviews, additive migration 0070 and API-only candidate `1539d35f4584…` deployed healthy at 19:31:24 +08. Candidate preserves two separately deployed friendship fixes absent from the local baseline. All seven deployed file hashes, live OpenAPI/auth/HTTPS readiness, unchanged other containers, isolated PG restore/concurrency and same-image Synapse alias gates passed.

Eleven legacy pending pairs recovered through public services with fresh metadata checks; eleven additional historical-source association operations completed. Final 65 canonicals preserve the original 54, pending 0, source rows 22. A full 22-operation replay made zero domain/audit/Outbox changes. Five exited canonical rooms intentionally remain unchanged; no forced joins or user-session minting. Explicit authorized-operations audit and raw metadata remain host-only under 0700 protection.

Detailed deployed digest, timestamps, exact rollback config/command locations, operator audit, test limitations and evidence: [production result](artifacts/2026-09-19/conversation-reliability/PRODUCTION-RESULT.md). Earlier undeployed/pending-gate paragraphs above are chronological evidence, superseded for the server by this section. Mobile integration/device acceptance remains root-owned.
