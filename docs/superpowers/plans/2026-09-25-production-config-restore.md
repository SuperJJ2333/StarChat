# Production Authentication and Configuration Restore Implementation Plan

> **For agentic workers:** Execute this plan in the current incident task with `superpowers:executing-plans`; review every production switch against the recorded preflight evidence. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the last verified production phone/SMS and related settings lost in the later 2026-09-24 API/worker deployment, while retaining the current wallet-360 code and all later database changes.

**Architecture:** Build new private API/worker Compose candidates from the currently running configurations and image IDs. Use the 2026-09-24 09:38 HKT verified `candidate-both-v4-private.json` as the latest approved value source for missing keys, keep secrets on the server, prove configuration and schema compatibility before switching only API/worker, and retain exact rollback snapshots. Existing-key financial policy changes require separate intent and transaction audit before a switch.

**Tech Stack:** Docker Compose JSON, FastAPI/Pydantic settings, PostgreSQL/Alembic, PowerShell 7 jump-host script.

**Authorization:** User explicitly requested production restoration on 2026-09-25. ADR-0075 and ADR-0078 remain the domain rules; no new authentication or finance policy is authorized. Root agent owns this plan, incident task/report, and all production mutation. Independent reviewers are read-only.

---

### Task 1: Freeze baseline and demonstrate the failure

**Files:**
- Read: `docs/verification/2026-09-25-mi6-login-sms-incident.md`
- Read: server `/opt/starchat/releases/wallet-360-t3-20260924/candidate-private.json`
- Read: server `/opt/starchat/releases/me-invitations-20260924/candidate-both-v4-private.json`
- Create: server `/opt/starchat/releases/mi6-auth-restore-20260925/` (0700, sensitive files 0600)
- Update: `docs/workflow/tasks/2026-09-25-mi6-login-sms-regression.md`

- [x] Record current API/worker container ID, image digest, health, restart count, Compose layers, DB revision, and other container identities without printing environment values.
- [x] Save exact current API/worker Compose and a current PostgreSQL backup in the server-private 0700 directory; record SHA256 and restore command. Do not download secrets or production data.
- [x] Assert the live configuration fails the intended policy: `phone_auth_enabled=false`, `sms_provider=disabled`, and `red_packet_owner_commission_enabled=true` despite the approved `true`/`aliyun_dypns`/`false` values. This is the red test; do not send an OTP.
- [x] Compare current and approved environment **key names** and all intersecting values privately; output only changed key names and safe feature booleans. Verify the 16 missing keys plus known financial policy differences, then audit whether latter were deliberate and whether financial records exist before deciding their intended values.

### Task 2: Prepare and verify the minimal candidate

**Files:**
- Create: server `/opt/starchat/releases/mi6-auth-restore-20260925/candidate-api-private.json`
- Create: server `/opt/starchat/releases/mi6-auth-restore-20260925/candidate-worker-private.json`
- Create: server `/opt/starchat/releases/mi6-auth-restore-20260925/candidate-manifest.json` (safe digest/key summary only)
- Update: `docs/verification/2026-09-25-mi6-production-restore.md`

- [x] Derive candidate JSON from current running Compose layers; copy exactly the approved missing values from the server-private 2026-09-24 v4 source, without writing values to logs or repository. Resolve existing-key finance flags from the wallet-360 release authorization and read-only ledger evidence; preserve the current wallet-360 image IDs and every unrelated setting.
- [x] Assert the candidate environment diff is exactly the reviewed missing-key set plus any separately approved existing-key restoration; both service images must equal the preflight digests.
- [x] In an isolated container using the candidate environment, run production `Settings()` assembly, SMS provider factory/import, refresh-auth contract and route checks without contacting the SMS provider or submitting credentials.
- [x] Confirm live schema revision `0088_profile_grapheme_limits` and verify candidate code/model compatibility on an isolated restored PostgreSQL copy. The running image lacks the 0088 migration script; the read-only ORM probe passed without modifying the production DB.
- [x] Complete ADR-0075 authentication/domain and ADR-0078 finance/domain review, followed by quality/security review. Stop on any unresolved behavior drift.

### Task 3: Switch and verify

**Files:**
- Update: `docs/verification/2026-09-25-mi6-production-restore.md`
- Update: `docs/workflow/tasks/2026-09-25-mi6-login-sms-regression.md`
- Update: `docs/workflow/current-state.md`

- [x] Verify candidate and rollback manifest SHA256, current container IDs, health and schema still match preflight. If any differ, regenerate the candidate and repeat checks.
- [x] Switch only API and worker using `/opt/starchat/ops/refresh-guards/business_release_guard.py deploy --compose <task-private API> --compose <task-private worker> --service business-api --service business-worker`; this existing guard checks both immutable images with nine refresh-protocol probes, freezes rendered Compose, and switches both roles. A task-private preflight must independently reject container/config/schema drift. Preserve all other containers, data volumes, DB content, and gateway configuration.
- [x] Verify API/worker healthy with zero restart loops; inspect actual runtime settings as safe booleans/provider name; confirm auth/phone routes exist and unauthenticated protected routes reject as expected. Use verified HTTPS from server and workstation. Do not trigger real SMS or financial writes.
- [x] Compare all other container identities, check worker health/restarts and new error markers, then update the incident report with actual timestamps, manifest/digests, check exit codes, and any remaining MI 6 login limitation.
- [x] Rollback condition did not occur. Exact pre-switch Compose snapshots and a guarded rollback path remain available; the failure path passed eight simulated tests. Never restore the production DB from backup over new writes.

**Acceptance:** Current wallet-360 behavior is retained; effective phone auth and Aliyun SMS assembly match the previously approved production setting; previously disabled owner commission remains disabled; no unreviewed environment value or container changes; rollback remains available; real user SMS/login success remains a separate device acceptance check.

**Execution:** Completed 2026-09-25 09:45 HKT; sustained read-only checks at 09:57 HKT passed. See [production restoration evidence](../../verification/2026-09-25-mi6-production-restore.md). The pre-existing worker Outbox dead-letter alert and absent 0088 migration script remain separate follow-up defects.
