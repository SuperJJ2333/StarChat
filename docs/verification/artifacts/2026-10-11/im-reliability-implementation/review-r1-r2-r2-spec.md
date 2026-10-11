# R2 independent specification/domain review

Reviewer: review_r1_r2. Review date: 2026-10-11 UTC+08. Candidate: commit 9d32bdfdf070278a071a4f4ccf671411a11d063d in im-push-reliability/StarChat; baseline 5c83a08a09b985146bc507a1608cb2153d361e48. Read approved plan R2, product push/E2EE boundaries, actual diff, unchanged sanitizer/provider client and all new tests before quality review.

Verdict: **SPEC/domain PASS** for R2's bounded scoped-admission and explicit-retry choice. No blocking deviation from the approved plan found.

| Requirement | Actual implementation/evidence |
| --- | --- |
| Different rooms/scopes get independent opportunity | Native key is CID + scope + room digest; A/B100ms and replacement scope tests assert two provider calls. Local mute remains a device policy; no gateway claim to know that policy. |
| Event dedup separate from room cooldown | Pending plus terminal table uses CID + scope + room + event; successful event remains accepted after room expiry; per-event permanent rejection persists across mixed-request retry. |
| Unaccepted work must not be silently acknowledged | Pending duplicates, room cooldown and table/provider capacity return503; no tail queue or false reliable-ownership claim. Accepted/rejected duplicates reuse known terminal results. |
| Bounded state, TTL and concurrency | Each native table bounded to8192, pending+completed combined8192; completed retention max300s/configured TTL, pending cannot expire mid-call; legacy table capped; process-wide four provider slots. |
| Reservation ownership | Revision guards prevent older failure deleting newer room opportunity; actual sync worker owns reservation and provider slot through termination. |
| Errors and compatibility | Transient/business/transport errors retry; permanent result remains rejected; existing legacy/call per-CID+kind behavior preserved. Call/legacy payload construction and v1 digest-only payload unchanged. |
| Required regression | Fresh `PYTHONPATH=services/getui-bridge python -m pytest -q -p no:cacheprovider tests/getui_bridge`:51 passed,2 pre-existing warnings,3.74s. Import preflight resolved app.main inside exact candidate tree. |

Candidate changes only main.py, rate_limit.py, a new test file and its report. No financial behavior, Matrix authorization, scoped wire format, push preference ownership or vendor channel is altered. The report accurately distinguishes provider acceptance from device receipt/display/sound.

The implementer's RED log records11 failures plus2 previously working transport cases before code, GREEN51 after, and baseline38. Tests are real sanitizer/rate-limit/thread/client execution with synthetic provider transport, not real vendor/device delivery. Equivalent whole-repository gates remain integration-owner work; absent .env is not bypassed.

Important scope: in-memory dedup is per process and TTL, not persistent exactly-once. Device arrival, OEM approval, real production load and multi-process operation are not established by these tests. Proceed to separate quality/security review of this same commit.
