# Retired private-chat destination correction

## Evidence and scope

Incident: Android0.3.97/2136 immediately fails messages to one iOS0.3.96 friend while other chats work. User supplied the pair; identifiers remain in protected host evidence. Reported year2025 differs from live release/server2026; inspected Beijing2026-09-19 20:30–20:37 (end exclusive). No message bodies, keys or user sessions were obtained.

The recorded primary exists but both participants left, joined count0 and successful state response empty. A single registered alternate has exactly both participants joined and Megolm encryption. There were no pair encrypted events and no room send requests in the interval. This supports a stale destination rejected before delivery, not a general Android/iOS incompatibility diagnosis. Device exception text was not collected.

[Task](../workflow/tasks/2026-09-19-retired-direct-room-repair.md), [plan](../superpowers/plans/2026-09-19-retired-direct-room-repair.md), [ADR amendment](../adr/2026-09-19-recoverable-direct-room-alias.md).

## Implementation and review

Operations-only public service compares the expected old destination under the pair lock and validates registered target, friendship, both blocking directions, strict Matrix retirement and exact joined/encrypted target evidence. It preserves stable conversation ID/history and writes actual-operator audit, Outbox and idempotency in the same transaction. Ordinary HTTP APIs and schemas are unchanged. No forced joins, room deletion or pending-message retargeting.

Specification review preceded independent quality/security review. Review findings about replay integrity, malformed membership and blocking during metadata I/O were repaired and verified. Final review found no blocking source issues. Matrix/business state are not globally atomic; ordinary blocking does not take this pair lock, leaving the documented final-query-to-commit window.

## Frozen candidate and tests

Base image `sha256:1539d35f4584e1b350fa9246dcf5c9214845e490e371438d4b3178a1ae39ecd4`; candidate `sha256:13f52c05533552c5c3180ae64d088257851802ff3011e43555a872629502f3a6` overlays only two files:

- `direct_room_recovery.py`: `0429a625d8f7edb8d04d8be2b4be741482e7420c1a8fedd00c4625aee43e95d7`.
- `matrix_admin.py`: `cced7e9fcdab1040d7a7c29284efd3a181a59a9a1e13ce2b9dae7a8d0c5cbb09`.

Existing production service/main source hashes are unchanged. Compose changes only the API image; schema remains0070. Protected backup restored successfully on isolated PostgreSQL. Eight concurrent synthetic corrections yielded one audit, one Outbox, one idempotency row, two retained sources; replay added zero rows. Active old room and a separately committed block during evidence collection were rejected. Isolated container returned to stopped/network-none.

Test-first evidence includes missing-method red, corrupt replay/malformed membership2 failing tests, and post-evidence blocking1 failing test, then green. Final focused suite:51 new repair tests plus30 neighboring recovery/coordination tests = **81 passed in35.67s**. Final test-only warning cleanup individually verified **1 passed in1.38s**, no warning. Tests also cover reversed-pair replay and transaction rollback when Outbox enqueue fails. Full `scripts/verify.ps1` completed with exit0 / Verification PASS at21:14+08: API/Worker2146 passed,58 skipped in1222.91s; mobile boundary70 passed; repository/deployment/infra/bridge/bot/import/AST/migration/OpenAPI/Compose checks passed. The run collected the test helper before its empty-match warning cleanup; its later single-test and102-test integrated reruns verify the final test file. Existing dependency deprecation warnings remain identified in the log; environment-dependent skipped integration tests are not claimed as executed. The separate real PostgreSQL repair gate supplies the incident's database-concurrency evidence.

Local artifact directory: `docs/verification/artifacts/2026-09-19/direct-send-2136/`; full gate log `verify-retired-repair.log`, sanitized production preparation under `production/`. Raw server evidence/backup/operation intent remain `/opt/starchat/releases/direct-send-2136-20260919` with restricted access.

Main advanced concurrently to `dc48cb95a9001b367e4f730052a982fe775a640f`. A separate detached integration worktree applied the byte-identical repair files/test. Four friendship files passed **102 tests in84.95s**. The wider five-file probe returned105 passed/1 failed: the unrelated red-packet test still expects20000.00 while main changed its default to200.00. Restoring both repair files to pure main and running that single test reproduced the same failure (1 failed in1.85s). No financial code/test was changed by this task. `main-integration-test.json` and its logs preserve both runs; this is not a claim that latest main's full suite passed.

## Publication and acceptance

Candidate deployed at21:15+08, healthy/schema0070 and source hashes verified; other containers unchanged. Fresh dry-run confirmed evidence, then the authorized selected-pair correction succeeded: one audit, one Outbox, one idempotency record, two retained sources. Same-key replay produced zero new audit/Outbox writes. Independent readback at21:16:48 confirmed both directions of both directory APIs select the target, retain both sources, preserve conversation ID/created_at and reservation, and record the actual operator. Ten Android/iOS update settings are unchanged; no new API ERROR/Traceback was found. Server TLS and workstation TLS checks completed by21:17:22: JSON health ready and three unauthenticated operations rejected401 on each side. Owned SOCKS tunnel was closed. Source commit `c7534a33` applies the byte-identical repair atop main `dc48cb95`. Android2136 APK/update settings and iOS2134 distribution are unchanged. Existing mobile build evidence is reused because no mobile source or dependency changed.

After correction, both directory queries must name the selected destination and retain the old source. Repeated repair must add zero writes. User acceptance requires returning to the conversation list, reentering after sync, and sending a **new** text. An old failed/uncertain bubble remains bound to its original room and is not a valid fresh-send test. Successful handset delivery is unverified until device feedback.
